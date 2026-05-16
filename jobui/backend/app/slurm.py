"""Slurm integration — render a job script from template, submit via sbatch,
parse squeue/sacct output.

The head node container shares /opt/slurm and /etc/munge with the host, so
`sbatch`, `squeue`, `sacct`, `scancel` all work as if run on the host.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
from pathlib import Path
from textwrap import dedent

from app.config import get_gpu_spec, get_settings
from app.models import Job, Model as ModelRow, Upload

SLURM_ENV = {
    **os.environ,
    "PATH": f"/opt/slurm/bin:/opt/slurm/sbin:{os.environ.get('PATH', '')}",
}


# ---------------------------------------------------------------------------
# Job script rendering
# ---------------------------------------------------------------------------

JOB_SCRIPT_TEMPLATE = dedent("""\
    #!/bin/bash
    #SBATCH --job-name={job_name}
    #SBATCH --partition={partition}
    #SBATCH --account={slurm_account}
    #SBATCH --gres=gpu:{gpu_count}
    #SBATCH --cpus-per-task={cpus}
    #SBATCH --mem={memory_mb}M
    #SBATCH --time={hours}:00:00
    #SBATCH --output=/fsx/work/%u/%j/slurm.log
    #SBATCH --error=/fsx/work/%u/%j/slurm.err
    #SBATCH --export=ALL,HPC_BUCKET,ECR_REGISTRY,AWS_REGION,AWS_DEFAULT_REGION

    set -euo pipefail

    WORK=/fsx/work/$USER/$SLURM_JOB_ID
    mkdir -p "$WORK/input" "$WORK/output"
    cd "$WORK"

    echo "[$(date)] job $SLURM_JOB_ID starting on $(hostname) with GPU(s)"
    nvidia-smi || true

    # --- Stage input from S3 ---
    echo "[$(date)] staging input from S3"
    s5cmd cp "s3://{s3_bucket}/{input_key}" input/

    # --- ECR login and container pull ---
    echo "[$(date)] logging into ECR"
    aws ecr get-login-password --region $AWS_REGION | \\
        docker login --username AWS --password-stdin {ecr_registry}

    echo "[$(date)] pulling {ecr_uri}"
    docker pull {ecr_uri}

    # --- Run inference ---
    echo "[$(date)] running inference"
    docker run --rm --gpus all \\
        --shm-size=8g \\
        {weights_mount}\\
        -v "$WORK/input:/data/input:ro" \\
        -v "$WORK/output:/data/output" \\
        -e NVIDIA_VISIBLE_DEVICES=all \\
        {ecr_uri} \\
        {weights_arg}\\
        {input_arg} /data/input/{input_filename} \\
        {output_arg} /data/output/ \\
        {extra_args}

    # --- Upload results to S3 ---
    echo "[$(date)] uploading results"
    for attempt in 1 2 3; do
        if s5cmd cp output/ "s3://{s3_bucket}/results/$SLURM_JOB_ID/"; then
            break
        fi
        echo "[$(date)] upload attempt $attempt failed, retrying in 5s..."
        sleep 5
    done

    # --- Cleanup FSx scratch ---
    cd /
    rm -rf "$WORK"

    echo "[$(date)] job $SLURM_JOB_ID complete"
""")


def render_job_script(
    job: Job, model: ModelRow, upload: Upload, username: str
) -> str:
    s = get_settings()
    spec = get_gpu_spec().get(job.gpu_family)
    if not spec:
        raise ValueError(f"no spec for GPU family {job.gpu_family}")

    # Weights mount: only if the model has a weights_path on FSx
    weights_mount = ""
    weights_arg = ""
    if model.weights_path:
        weights_mount = f"-v {model.weights_path}:/models:ro \\\n        "
        weights_arg = f"{model.weights_arg} /models \\\n        "

    # Input filename is the last path segment of the S3 key
    input_filename = upload.filename.split("/")[-1]

    return JOB_SCRIPT_TEMPLATE.format(
        job_name=f"{username}-{model.model_key}"[:60],
        partition=spec["partition"],
        slurm_account=job.slurm_account,
        gpu_count=job.gpu_count,
        cpus=spec["cpus_per_node"] // max(spec["gpus_per_node"], 1),
        memory_mb=int(spec["memory_mb"] * 0.9),  # leave headroom
        hours=job.requested_hours,
        s3_bucket=s.S3_BUCKET,
        input_key=upload.s3_key,
        ecr_registry=s.ECR_REGISTRY,
        ecr_uri=model.ecr_uri,
        weights_mount=weights_mount,
        weights_arg=weights_arg,
        input_arg=model.input_arg,
        output_arg=model.output_arg,
        input_filename=input_filename,
        extra_args=job.extra_args or model.extra_args or "",
    )


# ---------------------------------------------------------------------------
# Subprocess wrappers
# ---------------------------------------------------------------------------

def submit_job(script: str, username: str) -> int:
    """
    Write the script to /fsx/work/<user>/sbatch-<hash>.sh and submit it.
    Returns the Slurm job ID.
    """
    work_dir = Path(f"/fsx/work/{username}")
    work_dir.mkdir(parents=True, exist_ok=True)

    # Unique script name per submit
    import hashlib
    import time
    script_hash = hashlib.sha256(f"{script}{time.time()}".encode()).hexdigest()[:12]
    script_path = work_dir / f"sbatch-{script_hash}.sh"
    script_path.write_text(script)
    script_path.chmod(0o755)

    # Submit — we run sbatch as the unix user. For this MVP we submit as the
    # jobui service user and rely on Slurm's account-level isolation. In
    # production you'd `sudo -u <unix_user>` here.
    cmd = ["sbatch", "--parsable", str(script_path)]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=SLURM_ENV,
        timeout=30,
    )

    if result.returncode != 0:
        raise RuntimeError(f"sbatch failed: {result.stderr.strip()}")

    # Output is "<jobid>" or "<jobid>;<cluster>"
    out = result.stdout.strip().split(";")[0]
    return int(out)


def cancel_job(job_id: int) -> bool:
    result = subprocess.run(
        ["scancel", str(job_id)],
        capture_output=True,
        text=True,
        env=SLURM_ENV,
        timeout=10,
    )
    return result.returncode == 0


def get_job_status(job_id: int) -> dict | None:
    """Look up a job via squeue (if running/pending) or sacct (if finished)."""
    # Try squeue first — much faster for active jobs
    r = subprocess.run(
        ["squeue", "-j", str(job_id), "-h", "-o", "%T|%R|%N|%M"],
        capture_output=True,
        text=True,
        env=SLURM_ENV,
        timeout=10,
    )
    if r.returncode == 0 and r.stdout.strip():
        parts = r.stdout.strip().split("|")
        return {
            "state": parts[0],
            "reason": parts[1] if len(parts) > 1 else "",
            "node": parts[2] if len(parts) > 2 else "",
            "elapsed": parts[3] if len(parts) > 3 else "",
        }

    # Fall back to sacct for completed jobs
    r = subprocess.run(
        [
            "sacct", "-j", str(job_id), "-n", "-P",
            "-o", "State,ExitCode,Elapsed,NodeList,Start,End,TresUsageInTot",
        ],
        capture_output=True,
        text=True,
        env=SLURM_ENV,
        timeout=10,
    )
    if r.returncode == 0 and r.stdout.strip():
        # Take the .batch step row if present; first row otherwise
        lines = r.stdout.strip().split("\n")
        parts = lines[0].split("|")
        return {
            "state": parts[0],
            "exit_code": parts[1] if len(parts) > 1 else "",
            "elapsed": parts[2] if len(parts) > 2 else "",
            "node": parts[3] if len(parts) > 3 else "",
            "start": parts[4] if len(parts) > 4 else "",
            "end": parts[5] if len(parts) > 5 else "",
        }
    return None


def read_job_log(job_id: int, username: str, tail_lines: int = 500) -> str:
    """Read Slurm log from /fsx/work/<user>/<job>/slurm.log"""
    log_path = Path(f"/fsx/work/{username}/{job_id}/slurm.log")
    if not log_path.exists():
        return ""
    # Simple tail implementation
    with log_path.open("r", errors="replace") as f:
        lines = f.readlines()
    return "".join(lines[-tail_lines:])
