#!/bin/bash
# ============================================================================
# Titan HPC — reference inference job script.
#
# NOTE: This is a REFERENCE for CLI users.
# The web UI generates its own version of this script dynamically via
# app/slurm.py:render_job_script() with the chosen partition, GPU count,
# model URI, and input file. You don't need to edit this file — it's here
# as documentation of what the auto-generated script looks like.
# ============================================================================

#SBATCH --job-name=inference
#SBATCH --partition=gpu-a10g            # change to gpu-t4, gpu-h100-1x, etc.
#SBATCH --account=general               # or h100-approved
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=14G
#SBATCH --time=04:00:00
#SBATCH --output=/fsx/work/%u/%j/slurm.log
#SBATCH --error=/fsx/work/%u/%j/slurm.err

set -euo pipefail

# --- Configuration (override these via --export or edit in-place) ---
MODEL_URI="${MODEL_URI:-}"              # full ECR image URI with tag
MODEL_WEIGHTS_PATH="${MODEL_WEIGHTS_PATH:-}"   # e.g. /fsx/models/evo2/evo2-7b.pt
INPUT_S3_KEY="${INPUT_S3_KEY:-}"        # e.g. input/alice/uuid-xxx/sequences.fasta
S3_BUCKET="${HPC_BUCKET}"
ECR_REG="${ECR_REGISTRY}"

if [[ -z "$MODEL_URI" || -z "$INPUT_S3_KEY" ]]; then
    echo "ERROR: MODEL_URI and INPUT_S3_KEY must be set"
    exit 1
fi

WORK=/fsx/work/$USER/$SLURM_JOB_ID
mkdir -p "$WORK/input" "$WORK/output"
cd "$WORK"

echo "[$(date)] job $SLURM_JOB_ID starting on $(hostname)"
nvidia-smi || true

# --- Stage input from S3 ---
echo "[$(date)] staging input"
s5cmd cp "s3://$S3_BUCKET/$INPUT_S3_KEY" input/

# --- ECR login + pull ---
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REG"
docker pull "$MODEL_URI"

# --- Run ---
WEIGHTS_MOUNT=""
WEIGHTS_ARG=""
if [[ -n "$MODEL_WEIGHTS_PATH" ]]; then
    WEIGHTS_MOUNT="-v $MODEL_WEIGHTS_PATH:/models:ro"
    WEIGHTS_ARG="--weights /models"
fi

INPUT_FILE=$(basename "$INPUT_S3_KEY")

docker run --rm --gpus all \
    --shm-size=8g \
    $WEIGHTS_MOUNT \
    -v "$WORK/input:/data/input:ro" \
    -v "$WORK/output:/data/output" \
    -e NVIDIA_VISIBLE_DEVICES=all \
    "$MODEL_URI" \
    $WEIGHTS_ARG \
    --input "/data/input/$INPUT_FILE" \
    --output /data/output/

# --- Upload results ---
for attempt in 1 2 3; do
    if s5cmd cp output/ "s3://$S3_BUCKET/results/$SLURM_JOB_ID/"; then break; fi
    echo "[$(date)] upload attempt $attempt failed, retrying..."
    sleep 5
done

# --- Cleanup ---
cd /
rm -rf "$WORK"
echo "[$(date)] job complete"
