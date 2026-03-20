#!/bin/bash
#SBATCH --job-name=fsx-test
#SBATCH --output=/fsx/work/%u/out_%A_%a.txt
#SBATCH --error=/fsx/work/%u/err_%A_%a.txt
#SBATCH --array=1-4
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:05:00

echo "=== FSx Test Job ==="
echo "Job ID   : $SLURM_JOB_ID"
echo "Array ID : $SLURM_ARRAY_TASK_ID"
echo "Node     : $(hostname)"
echo "User     : $(whoami) (uid=$(id -u))"
echo "Date     : $(date)"

# Write a file unique to this array task
OUTFILE="/fsx/work/$USER/result_${SLURM_ARRAY_TASK_ID}.txt"
echo "Array task $SLURM_ARRAY_TASK_ID completed on $(hostname) at $(date)" > "$OUTFILE"

# Append to shared log
echo "[task $SLURM_ARRAY_TASK_ID] $(hostname) $(date)" >> /fsx/shared/fsx_test.log

# Verify the file was written
echo "Output file:"
cat "$OUTFILE"

echo "=== Done ==="
