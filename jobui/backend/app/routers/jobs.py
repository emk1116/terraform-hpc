from fastapi import APIRouter, HTTPException, Depends, status
from typing import List, Dict, Any

from app.models.schemas import JobSubmitRequest, JobResponse, LogResponse, ResultFile
from app.auth.dependencies import get_current_user
from app.config import get_settings
from app.database import get_job, list_jobs, update_job
from app.services import job_service, slurm_service
from app.utils.logging import get_logger

router = APIRouter(prefix="/jobs", tags=["jobs"])
logger = get_logger(__name__)

TERMINAL_STATES = {"COMPLETED", "FAILED", "CANCELLED"}


def _job_to_response(job: Dict[str, Any]) -> JobResponse:
    return JobResponse(
        id=job["id"],
        slurm_job_id=job.get("slurm_job_id"),
        user_id=job["user_id"],
        cluster_user=job["cluster_user"],
        name=job["name"],
        status=job["status"],
        input_prefix=job["input_prefix"],
        cpus=job["cpus"],
        memory_mb=job["memory_mb"],
        time_limit=job["time_limit"],
        command=job["command"],
        created_at=job["created_at"],
        updated_at=job["updated_at"],
        error_message=job.get("error_message"),
    )


@router.post("", response_model=JobResponse, status_code=status.HTTP_201_CREATED)
async def submit_job(
    request: JobSubmitRequest,
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> JobResponse:
    settings = get_settings()

    if not settings.s3_bucket:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="S3 bucket is not configured",
        )

    if not slurm_service.is_available():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Slurm is not available on this system",
        )

    return await job_service.submit_job(
        request=request,
        current_user=current_user,
        db_path=settings.db_path,
        settings=settings,
    )


@router.get("", response_model=List[JobResponse])
async def list_jobs_endpoint(
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> List[JobResponse]:
    settings = get_settings()
    jobs = list_jobs(
        db_path=settings.db_path,
        user_id=current_user["id"],
        is_admin=bool(current_user.get("is_admin")),
    )
    return [_job_to_response(j) for j in jobs]


@router.get("/{job_id}", response_model=JobResponse)
async def get_job_endpoint(
    job_id: str,
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> JobResponse:
    settings = get_settings()
    user_id = None if current_user.get("is_admin") else current_user["id"]
    job = get_job(settings.db_path, job_id, user_id)

    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id} not found",
        )

    if job["status"] not in TERMINAL_STATES and job.get("slurm_job_id"):
        job = await job_service.refresh_job_status(job, settings.db_path)

    return _job_to_response(job)


@router.get("/{job_id}/logs", response_model=LogResponse)
async def get_job_logs(
    job_id: str,
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> LogResponse:
    settings = get_settings()
    user_id = None if current_user.get("is_admin") else current_user["id"]
    job = get_job(settings.db_path, job_id, user_id)

    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id} not found",
        )

    return job_service.get_logs(
        job_id=job_id,
        cluster_user=job["cluster_user"],
        db_path=settings.db_path,
        fsx_base=settings.fsx_base,
    )


@router.get("/{job_id}/results", response_model=List[ResultFile])
async def get_job_results(
    job_id: str,
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> List[ResultFile]:
    settings = get_settings()
    user_id = None if current_user.get("is_admin") else current_user["id"]
    job = get_job(settings.db_path, job_id, user_id)

    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id} not found",
        )

    if not settings.s3_bucket:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="S3 bucket is not configured",
        )

    return job_service.get_results(
        job_id=job_id,
        user_id=current_user["id"],
        db_path=settings.db_path,
        settings=settings,
    )


@router.delete("/{job_id}", status_code=status.HTTP_204_NO_CONTENT)
async def cancel_job(
    job_id: str,
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> None:
    settings = get_settings()
    user_id = None if current_user.get("is_admin") else current_user["id"]
    job = get_job(settings.db_path, job_id, user_id)

    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id} not found",
        )

    if job["status"] in TERMINAL_STATES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Job is already in terminal state: {job['status']}",
        )

    if not slurm_service.is_available():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Slurm is not available on this system",
        )

    if job.get("slurm_job_id"):
        try:
            slurm_service.cancel_job(job["slurm_job_id"], job["cluster_user"])
        except RuntimeError as e:
            logger.error(
                "Failed to cancel slurm job",
                extra={"job_id": job_id, "slurm_job_id": job["slurm_job_id"], "error": str(e)},
            )
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Failed to cancel Slurm job: {e}",
            )

    update_job(settings.db_path, job_id, {"status": "CANCELLED"})
    logger.info(
        "Job cancelled",
        extra={"user_id": current_user["id"], "job_id": job_id},
    )
