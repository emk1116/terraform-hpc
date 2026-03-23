import subprocess
import shutil
from typing import Optional
from app.utils.logging import get_logger

logger = get_logger(__name__)

_STATE_MAP = {
    "PENDING": "PENDING",
    "RUNNING": "RUNNING",
    "CONFIGURING": "RUNNING",
    "COMPLETING": "RUNNING",
    "COMPLETED": "COMPLETED",
    "FAILED": "FAILED",
    "CANCELLED": "CANCELLED",
    "CANCELLED+": "CANCELLED",
    "TIMEOUT": "FAILED",
    "NODE_FAIL": "FAILED",
    "OUT_OF_MEMORY": "FAILED",
    "PREEMPTED": "FAILED",
    "BOOT_FAIL": "FAILED",
    "DEADLINE": "FAILED",
}


def submit_job(script_path: str, cluster_user: str) -> int:
    try:
        result = subprocess.run(
            ["sudo", "-u", cluster_user, "sbatch", "--parsable", script_path],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("sbatch command timed out after 30 seconds")
    except FileNotFoundError:
        raise RuntimeError("sudo or sbatch command not found")

    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise RuntimeError(f"sbatch failed (exit {result.returncode}): {stderr}")

    stdout = result.stdout.strip()
    # --parsable output is "<jobid>" or "<jobid>;<cluster>"
    job_id_str = stdout.split(";")[0].strip()
    try:
        return int(job_id_str)
    except ValueError:
        raise RuntimeError(f"Could not parse Slurm job ID from sbatch output: {stdout!r}")


def get_status(slurm_job_id: int) -> str:
    try:
        result = subprocess.run(
            [
                "sacct",
                "-j", str(slurm_job_id),
                "--format=State",
                "--noheader",
                "-P",
                "--allocations",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        logger.warning("sacct timed out", extra={"slurm_job_id": slurm_job_id})
        return "UNKNOWN"
    except FileNotFoundError:
        return "UNKNOWN"

    if result.returncode != 0:
        logger.warning(
            "sacct returned non-zero",
            extra={"slurm_job_id": slurm_job_id, "stderr": result.stderr.strip()},
        )
        return "UNKNOWN"

    lines = [line.strip() for line in result.stdout.strip().splitlines() if line.strip()]
    if not lines:
        return "UNKNOWN"

    # Take the first non-empty state line
    raw_state = lines[0].upper()
    # State may have modifiers like "CANCELLED by 1000"
    state_part = raw_state.split(" ")[0].rstrip("+")

    return _STATE_MAP.get(state_part, "UNKNOWN")


def cancel_job(slurm_job_id: int, cluster_user: str) -> None:
    try:
        result = subprocess.run(
            ["sudo", "-u", cluster_user, "scancel", str(slurm_job_id)],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("scancel command timed out after 30 seconds")
    except FileNotFoundError:
        raise RuntimeError("sudo or scancel command not found")

    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise RuntimeError(f"scancel failed (exit {result.returncode}): {stderr}")


def is_available() -> bool:
    return shutil.which("sbatch") is not None
