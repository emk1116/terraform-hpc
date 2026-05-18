"""Jobs router — submit, list, detail, cancel."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import get_current_user
from app.config import get_gpu_spec
from app.costing import check_budget_or_raise, estimate_cost_usd
from app.database import get_db
from app.models import (
    AppUser,
    AuditLog,
    Job,
    JobStatus,
    Model as ModelRow,
    Upload,
    UploadStatus,
    UserRole,
)
from app.s3_uploads import list_prefix, presign_get_url
from app.schemas import JobDetail, JobOut, JobSubmitRequest, JobSubmitResponse
from app.slurm import (
    cancel_job as slurm_cancel,
    get_job_status,
    read_job_log,
    render_job_script,
    submit_job,
)

router = APIRouter(prefix="/api/jobs", tags=["jobs"])


@router.post("", response_model=JobSubmitResponse, status_code=201)
def submit(
    req: JobSubmitRequest,
    request: Request,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    # --- Validate GPU family ---
    spec = get_gpu_spec().get(req.gpu_family)
    if not spec:
        raise HTTPException(status_code=400, detail=f"Unknown GPU family {req.gpu_family}")

    # H100 approval gate
    if req.gpu_family.startswith("h100") and not user.h100_approved:
        raise HTTPException(
            status_code=403,
            detail="H100 use requires admin approval. Contact your team admin.",
        )

    # --- Validate upload ---
    upload = db.get(Upload, req.upload_id)
    if not upload or upload.user_id != user.id:
        raise HTTPException(status_code=404, detail="Upload not found")
    if upload.status != UploadStatus.completed:
        raise HTTPException(status_code=409, detail="Upload is not complete")

    # --- Validate model ---
    model = db.get(ModelRow, req.model_id)
    if not model or not model.is_active:
        raise HTTPException(status_code=404, detail="Model not found or inactive")
    if req.gpu_family not in model.allowed_gpus:
        raise HTTPException(
            status_code=400,
            detail=f"Model {model.model_key} does not allow GPU {req.gpu_family}",
        )
    if model.gpu_min_memory_gb > spec["gpu_memory_gb"]:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Model requires {model.gpu_min_memory_gb} GB GPU memory; "
                f"{req.gpu_family} only has {spec['gpu_memory_gb']} GB"
            ),
        )

    # --- Runtime cap ---
    if req.requested_hours > model.max_runtime_hours:
        raise HTTPException(
            status_code=400,
            detail=f"requested_hours exceeds model max ({model.max_runtime_hours})",
        )

    # --- Cost estimation + budget check ---
    estimated = estimate_cost_usd(req.gpu_family, req.requested_hours)
    check_budget_or_raise(db, user, estimated)

    # --- Create Job row before sbatch so we can recover on failure ---
    job = Job(
        user_id=user.id,
        model_id=model.id,
        upload_id=upload.id,
        gpu_family=req.gpu_family,
        gpu_count=req.gpu_count,
        requested_hours=req.requested_hours,
        slurm_account=user.slurm_account,
        partition=spec["partition"],
        status=JobStatus.submitted,
        estimated_cost_usd=estimated,
        extra_args=req.extra_args,
    )
    db.add(job)
    db.flush()  # assigns id

    # --- Render script and sbatch ---
    script = render_job_script(job, model, upload, user.username)

    try:
        slurm_id = submit_job(script, user.username)
    except Exception as e:
        job.status = JobStatus.failed
        db.commit()
        raise HTTPException(status_code=500, detail=f"sbatch failed: {e}") from e

    job.slurm_job_id = slurm_id
    job.status = JobStatus.pending

    client_ip = request.headers.get("X-Forwarded-For", request.client.host if request.client else None)
    db.add(
        AuditLog(
            user_id=user.id,
            action="submit_job",
            target_type="job",
            target_id=str(job.id),
            ip_address=client_ip,
            details={
                "slurm_job_id": slurm_id,
                "gpu_family": req.gpu_family,
                "model": model.model_key,
                "estimated_cost": str(estimated),
            },
        )
    )
    db.commit()

    return JobSubmitResponse(
        job_id=job.id,
        slurm_job_id=slurm_id,
        estimated_cost_usd=estimated,
        partition=spec["partition"],
    )


@router.get("", response_model=list[JobOut])
def list_jobs(
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
    limit: int = 50,
):
    stmt = (
        select(Job, ModelRow.model_key, ModelRow.display_name)
        .join(ModelRow, Job.model_id == ModelRow.id)
        .order_by(Job.submitted_at.desc())
        .limit(limit)
    )
    if user.role != UserRole.admin:
        stmt = stmt.where(Job.user_id == user.id)
    rows = db.execute(stmt).all()
    return [
        JobOut.model_validate(job).model_copy(
            update={"model_key": mk, "model_display_name": mdn}
        )
        for job, mk, mdn in rows
    ]


@router.get("/{job_id}", response_model=JobDetail)
def get_job_detail(
    job_id: int,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    job = db.get(Job, job_id)
    if not job or (user.role != UserRole.admin and job.user_id != user.id):
        raise HTTPException(status_code=404, detail="Job not found")

    # Get Slurm-side status
    slurm_info = {}
    if job.slurm_job_id:
        slurm_info = get_job_status(job.slurm_job_id) or {}

    # Log tail
    log_tail = ""
    if job.slurm_job_id:
        try:
            target_user = (
                db.get(AppUser, job.user_id).username
                if user.role == UserRole.admin
                else user.username
            )
            log_tail = read_job_log(job.slurm_job_id, target_user, tail_lines=300)
        except Exception:
            log_tail = ""

    # Result files with presigned URLs (only for completed jobs)
    result_files = None
    if job.slurm_job_id and job.status in (JobStatus.completed, JobStatus.failed):
        prefix = f"results/{job.slurm_job_id}/"
        files = list_prefix(prefix)
        result_files = [
            {
                "key": f["key"],
                "size": f["size"],
                "url": presign_get_url(f["key"]),
            }
            for f in files
        ]

    # Merge
    data = JobOut.model_validate(job).model_dump()
    return JobDetail(
        **data,
        slurm_state=slurm_info.get("state"),
        slurm_reason=slurm_info.get("reason"),
        slurm_node=slurm_info.get("node"),
        log_tail=log_tail,
        result_files=result_files,
    )


@router.post("/{job_id}/cancel", status_code=204)
def cancel_job(
    job_id: int,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    job = db.get(Job, job_id)
    if not job or (user.role != UserRole.admin and job.user_id != user.id):
        raise HTTPException(status_code=404, detail="Job not found")

    if job.slurm_job_id and job.status in (
        JobStatus.submitted,
        JobStatus.pending,
        JobStatus.running,
    ):
        slurm_cancel(job.slurm_job_id)
        job.status = JobStatus.cancelled

    db.add(
        AuditLog(
            user_id=user.id,
            action="cancel_job",
            target_type="job",
            target_id=str(job.id),
        )
    )
    db.commit()
