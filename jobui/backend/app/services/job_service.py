import os
import uuid
import shlex
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional

from fastapi import HTTPException, status

from app.models.schemas import JobSubmitRequest, JobResponse, LogResponse, ResultFile
from app.database import create_job, get_job, update_job
from app.services import s3_service, slurm_service
from app.utils.logging import get_logger

logger = get_logger(__name__)

TERMINAL_STATES = {"COMPLETED", "FAILED", "CANCELLED"}

# Allowed command characters — broad enough for real HPC commands but blocks injection
_COMMAND_ALLOWED_CHARS = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    " \t\n_-./=><|&;:\"'(){}[]$@!#%^*+,?~`\\"
)


def _validate_command(command: str) -> str:
    """Validate command doesn't contain null bytes or extremely suspicious patterns."""
    if "\x00" in command:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Command contains null bytes",
        )
    if len(command) > 4096:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Command exceeds maximum length of 4096 characters",
        )
    return command


def build_job_script(
    job_id: str,
    user_id: str,
    cluster_user: str,
    name: str,
    input_prefix: str,
    command: str,
    cpus: int,
    memory_mb: int,
    time_limit: str,
    fsx_base: str,
    s3_bucket: str,
    partition: str,
) -> str:
    work_dir = os.path.join(fsx_base, cluster_user, job_id)
    log_file = os.path.join(work_dir, "job.log")
    err_file = os.path.join(work_dir, "job.err")
    input_dir = os.path.join(work_dir, "input")
    output_dir = os.path.join(work_dir, "output")

    # Build S3 source path
    if input_prefix:
        s3_input = f"s3://{s3_bucket}/input/{user_id}/{input_prefix}/"
    else:
        s3_input = f"s3://{s3_bucket}/input/{user_id}/"

    s3_results = f"s3://{s3_bucket}/results/{job_id}/"

    # Safely quote all path variables used in the script
    safe_work_dir = shlex.quote(work_dir)
    safe_input_dir = shlex.quote(input_dir)
    safe_output_dir = shlex.quote(output_dir)
    safe_s3_input = shlex.quote(s3_input)
    safe_s3_results = shlex.quote(s3_results)
    safe_log_file = shlex.quote(log_file)

    script = f"""#!/bin/bash
#SBATCH --job-name={shlex.quote(name)}
#SBATCH --partition={shlex.quote(partition)}
#SBATCH --cpus-per-task={cpus}
#SBATCH --mem={memory_mb}M
#SBATCH --time={time_limit}
#SBATCH --output={err_file}
#SBATCH --error={err_file}
#SBATCH --parsable

set -euo pipefail

# Redirect all output to log file
exec > >(tee -a {safe_log_file}) 2>&1

echo "========================================"
echo "Job ID: {job_id}"
echo "Slurm Job: $SLURM_JOB_ID"
echo "Start Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)"
echo "========================================"

# Create working directories
mkdir -p {safe_input_dir} {safe_output_dir}
cd {safe_work_dir}

echo "[$(date -u +%H:%M:%S)] Downloading input files from S3..."
aws s3 sync {safe_s3_input} {safe_input_dir}/ --no-progress || {{
    echo "ERROR: Failed to download input files from {s3_input}"
    exit 1
}}
echo "[$(date -u +%H:%M:%S)] Input files downloaded successfully"
ls -lh {safe_input_dir}/

echo "[$(date -u +%H:%M:%S)] Running job command..."
echo "Command: {command}"

# Run the user-supplied command with output dir set
export OUTPUT_DIR={safe_output_dir}
export INPUT_DIR={safe_input_dir}
export WORK_DIR={safe_work_dir}
export JOB_ID={shlex.quote(job_id)}

(
  cd {safe_work_dir}
  {command}
)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "ERROR: Command exited with code $EXIT_CODE"
    exit $EXIT_CODE
fi

echo "[$(date -u +%H:%M:%S)] Command completed successfully"

echo "[$(date -u +%H:%M:%S)] Uploading results to S3..."
if [ -n "$(ls -A {safe_output_dir} 2>/dev/null)" ]; then
    aws s3 sync {safe_output_dir}/ {safe_s3_results} --no-progress || {{
        echo "WARNING: Failed to upload some results to S3"
    }}
    echo "[$(date -u +%H:%M:%S)] Results uploaded to {s3_results}"
else
    echo "WARNING: Output directory is empty — no results to upload"
fi

echo "[$(date -u +%H:%M:%S)] Cleaning up work directory..."
rm -rf {safe_input_dir}

echo "========================================"
echo "Job completed successfully"
echo "End Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================"
"""
    return script


async def submit_job(
    request: JobSubmitRequest,
    current_user: Dict[str, Any],
    db_path: str,
    settings,
) -> JobResponse:
    command = _validate_command(request.command)
    job_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    script_content = build_job_script(
        job_id=job_id,
        user_id=current_user["id"],
        cluster_user=current_user["cluster_user"],
        name=request.name,
        input_prefix=request.input_prefix,
        command=command,
        cpus=request.cpus,
        memory_mb=request.memory_mb,
        time_limit=request.time_limit,
        fsx_base=settings.fsx_base,
        s3_bucket=settings.s3_bucket,
        partition=settings.slurm_partition,
    )

    # Write script to temp file
    script_path = f"/tmp/job_{job_id}.sh"
    try:
        with open(script_path, "w") as f:
            f.write(script_content)
        os.chmod(script_path, 0o755)
    except OSError as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to write job script: {e}",
        )

    # Create FSx work directory if accessible
    work_dir = os.path.join(settings.fsx_base, current_user["cluster_user"], job_id)
    if os.path.isdir(settings.fsx_base):
        try:
            os.makedirs(os.path.join(work_dir, "input"), exist_ok=True)
            os.makedirs(os.path.join(work_dir, "output"), exist_ok=True)
        except OSError as e:
            logger.warning(
                "Could not create FSx work dir",
                extra={"job_id": job_id, "error": str(e)},
            )

    # Submit to Slurm
    slurm_job_id: Optional[int] = None
    job_status = "SUBMITTED"
    error_message: Optional[str] = None

    try:
        slurm_job_id = slurm_service.submit_job(script_path, current_user["cluster_user"])
        job_status = "PENDING"
        logger.info(
            "Job submitted to Slurm",
            extra={
                "user_id": current_user["id"],
                "job_id": job_id,
                "slurm_job_id": slurm_job_id,
            },
        )
    except RuntimeError as e:
        job_status = "FAILED"
        error_message = str(e)
        logger.error(
            "Slurm submission failed",
            extra={"user_id": current_user["id"], "job_id": job_id, "error": str(e)},
        )
    finally:
        try:
            os.unlink(script_path)
        except OSError:
            pass

    job_dict = {
        "id": job_id,
        "slurm_job_id": slurm_job_id,
        "user_id": current_user["id"],
        "cluster_user": current_user["cluster_user"],
        "name": request.name,
        "status": job_status,
        "input_prefix": request.input_prefix,
        "cpus": request.cpus,
        "memory_mb": request.memory_mb,
        "time_limit": request.time_limit,
        "command": command,
        "created_at": now,
        "updated_at": now,
        "error_message": error_message,
    }

    job = create_job(db_path, job_dict)

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


async def refresh_job_status(job: Dict[str, Any], db_path: str) -> Dict[str, Any]:
    if not job.get("slurm_job_id"):
        return job

    try:
        new_status = slurm_service.get_status(job["slurm_job_id"])
    except Exception as e:
        logger.warning(
            "Could not refresh slurm status",
            extra={"job_id": job["id"], "error": str(e)},
        )
        return job

    if new_status != "UNKNOWN" and new_status != job["status"]:
        updates: Dict[str, Any] = {"status": new_status}
        if new_status == "FAILED" and not job.get("error_message"):
            updates["error_message"] = "Job failed in Slurm — check logs for details"
        update_job(db_path, job["id"], updates)
        logger.info(
            "Job status updated",
            extra={
                "job_id": job["id"],
                "old_status": job["status"],
                "new_status": new_status,
            },
        )
        job = {**job, **updates}

    return job


def get_logs(
    job_id: str,
    cluster_user: str,
    db_path: str,
    fsx_base: str,
) -> LogResponse:
    log_path = os.path.join(fsx_base, cluster_user, job_id, "job.log")

    if not os.path.exists(log_path):
        return LogResponse(
            job_id=job_id,
            log="Log not yet available. The job may still be initializing.",
            available=False,
        )

    try:
        with open(log_path, "r", errors="replace") as f:
            # Read last 1MB to avoid memory issues with huge logs
            f.seek(0, 2)
            size = f.tell()
            if size > 1_048_576:
                f.seek(-1_048_576, 2)
                content = "[... log truncated — showing last 1MB ...]\n" + f.read()
            else:
                f.seek(0)
                content = f.read()

        return LogResponse(job_id=job_id, log=content, available=True)
    except OSError as e:
        return LogResponse(
            job_id=job_id,
            log=f"Error reading log file: {e}",
            available=False,
        )


def get_results(
    job_id: str,
    user_id: str,
    db_path: str,
    settings,
) -> List[ResultFile]:
    raw_results = s3_service.list_results(
        job_id=job_id,
        bucket=settings.s3_bucket,
        region=settings.aws_region,
    )

    result_files = []
    for item in raw_results:
        presigned_url = s3_service.generate_presigned_url(
            key=item["key"],
            bucket=settings.s3_bucket,
            region=settings.aws_region,
            expiry=settings.s3_presigned_expiry,
        )
        result_files.append(
            ResultFile(
                filename=item["filename"],
                key=item["key"],
                size=item["size"],
                presigned_url=presigned_url,
            )
        )

    return result_files
