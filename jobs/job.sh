#!/bin/bash
#SBATCH --job-name=hpc-array-demo
#SBATCH --output=/tmp/job_%A_%a.out
#SBATCH --error=/tmp/job_%A_%a.err
#SBATCH --array=1-10
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=256M
#SBATCH --time=00:05:00
#SBATCH --partition=main


echo "======================================"
echo "Job Array ID   : $SLURM_ARRAY_JOB_ID"
echo "Task ID        : $SLURM_ARRAY_TASK_ID"
echo "Job Name       : $SLURM_JOB_NAME"
echo "Node           : $(hostname)"
echo "Date           : $(date)"
echo "======================================"

# Simulate work based on task ID
TASK_ID=$SLURM_ARRAY_TASK_ID
echo "Processing task $TASK_ID of 10..."
sleep $((TASK_ID * 2))
echo "Task $TASK_ID completed on $(hostname) at $(date)"
