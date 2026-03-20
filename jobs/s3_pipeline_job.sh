#!/bin/bash
#SBATCH --job-name=s3-pipeline
#SBATCH --output=/fsx/work/%u/job_%j.log
#SBATCH --error=/fsx/work/%u/job_%j.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:30:00

set -euo pipefail

JOB_ID=$SLURM_JOB_ID
USER_NAME=$USER
NODE=$(hostname)

# HPC_BUCKET is set by /etc/profile.d/hpc-pipeline.sh on all nodes.
# Fall back to /etc/environment if not already in environment.
if [ -z "${HPC_BUCKET:-}" ]; then
  HPC_BUCKET=$(grep "^HPC_BUCKET=" /etc/environment | cut -d= -f2)
fi

if [ -z "$HPC_BUCKET" ]; then
  echo "ERROR: HPC_BUCKET not set. Check /etc/environment on this node." >&2
  exit 1
fi

S3_INPUT="s3://$HPC_BUCKET/input"
S3_OUTPUT="s3://$HPC_BUCKET/results/$JOB_ID"
WORK_DIR="/fsx/work/$USER_NAME/$JOB_ID"

echo "============================================================"
echo " S3 Pipeline Job"
echo "============================================================"
echo " Job ID  : $JOB_ID"
echo " User    : $USER_NAME (uid=$(id -u))"
echo " Node    : $NODE"
echo " Started : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo " Bucket  : $HPC_BUCKET"
echo " Input   : $S3_INPUT"
echo " Output  : $S3_OUTPUT"
echo " WorkDir : $WORK_DIR"
echo "============================================================"

# ── Step 1: Create per-job working directory ───────────────────────────────────
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ── Step 2: Verify input exists in S3 ─────────────────────────────────────────
echo "[$(date -u +%H:%M:%S)] Checking S3 input..."
INPUT_COUNT=$(aws s3 ls "$S3_INPUT/" 2>/dev/null | grep -v "/$" | wc -l)
if [ "$INPUT_COUNT" -eq 0 ]; then
  echo "WARNING: No input files found at $S3_INPUT/" >&2
  echo "         Upload files with: aws s3 cp <file> $S3_INPUT/" >&2
  echo "         Continuing with empty input (demo mode)."
fi
echo "[$(date -u +%H:%M:%S)] Found $INPUT_COUNT input file(s)."

# ── Step 3: Download input from S3 to FSx ─────────────────────────────────────
echo "[$(date -u +%H:%M:%S)] Downloading input from S3..."
for attempt in 1 2 3; do
  aws s3 cp "$S3_INPUT/" "$WORK_DIR/input/" --recursive --quiet && break
  echo "  S3 download attempt $attempt/3 failed. Retrying in 5s..."
  sleep 5
  if [ "$attempt" -eq 3 ]; then
    echo "ERROR: S3 download failed after 3 attempts." >&2
    exit 1
  fi
done
echo "[$(date -u +%H:%M:%S)] Download complete."

# ── Step 4: Process data (replace this block with your workload) ───────────────
echo "[$(date -u +%H:%M:%S)] Processing data on $NODE..."
mkdir -p "$WORK_DIR/output"

# Summarize input files
echo "=== Input File Summary ===" > "$WORK_DIR/output/summary.txt"
echo "Job ID    : $JOB_ID"        >> "$WORK_DIR/output/summary.txt"
echo "Node      : $NODE"          >> "$WORK_DIR/output/summary.txt"
echo "Timestamp : $(date -u)"     >> "$WORK_DIR/output/summary.txt"
echo "Files     :"                >> "$WORK_DIR/output/summary.txt"

shopt -s nullglob
for f in "$WORK_DIR/input/"*; do
  SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
  echo "  - $(basename $f) ($SIZE bytes)" >> "$WORK_DIR/output/summary.txt"
done
shopt -u nullglob

# Simulate workload
sleep 5

echo "Processed by $NODE at $(date -u)" >> "$WORK_DIR/output/summary.txt"
echo "[$(date -u +%H:%M:%S)] Processing complete."

# ── Step 5: Upload results to S3 ──────────────────────────────────────────────
echo "[$(date -u +%H:%M:%S)] Uploading results to $S3_OUTPUT/..."
for attempt in 1 2 3; do
  aws s3 cp "$WORK_DIR/output/" "$S3_OUTPUT/" --recursive --quiet && break
  echo "  S3 upload attempt $attempt/3 failed. Retrying in 5s..."
  sleep 5
  if [ "$attempt" -eq 3 ]; then
    echo "ERROR: S3 upload failed after 3 attempts." >&2
    exit 1
  fi
done
echo "[$(date -u +%H:%M:%S)] Upload complete."

# ── Step 6: Verify upload ─────────────────────────────────────────────────────
echo "[$(date -u +%H:%M:%S)] Verifying S3 output..."
aws s3 ls "$S3_OUTPUT/" --recursive

# ── Step 7: Clean up FSx work dir ─────────────────────────────────────────────
echo "[$(date -u +%H:%M:%S)] Cleaning up FSx work directory..."
rm -rf "$WORK_DIR"
echo "[$(date -u +%H:%M:%S)] Cleanup done."

echo "============================================================"
echo " Job $JOB_ID COMPLETED"
echo " Results at: $S3_OUTPUT/"
echo " View with : aws s3 ls $S3_OUTPUT/"
echo "============================================================"
