#!/bin/bash
#SBATCH --job-name=fsx-warmup
#SBATCH --partition=gpu-t4
#SBATCH --account=general
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:15:00
#SBATCH --output=/fsx/work/%u/%j/slurm.log

# Simple smoke test: prove a GPU node can:
#  1. Mount FSx
#  2. Access S3 via s5cmd
#  3. See the GPU
#  4. Docker works and can use GPUs

set -euo pipefail
WORK=/fsx/work/$USER/$SLURM_JOB_ID
mkdir -p "$WORK"
cd "$WORK"

echo "[$(date)] smoke test on $(hostname)"
nvidia-smi
echo "---"
mount | grep fsx
echo "---"
s5cmd ls "s3://$HPC_BUCKET/" | head -20
echo "---"
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
echo "[$(date)] smoke test passed"
