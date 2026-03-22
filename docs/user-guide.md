# Titan HPC — User Guide

This guide walks you through the full workflow: uploading your model and input data to S3, submitting a Slurm job, and retrieving your results.

---

## Overview

```
Your Machine          Login Node              Compute Node             S3 Bucket
────────────          ──────────              ────────────             ─────────
Upload data     ──►   Submit job   ──►   Download from S3
                                          Process data
                                          Upload results  ──────────►  results/<job_id>/
                      Check status        Clean up FSx
Retrieve results ◄────────────────────────────────────────────────── Download results
```

No data movement is manual. The job handles everything automatically.

---

## Step 1 — Connect to the Login Node

You can only access the cluster through the login node. Get the IP from your administrator or from the Terraform output.

```bash
ssh -i ~/.ssh/titan-hpc ec2-user@<login_node_ip>
```

You will see the cluster banner on login. This node is for **job submission only** — do not run compute workloads here.

---

## Step 2 — Upload Your Data to S3

Do this from **your local machine** (not the login node), or from the login node if the AWS CLI is configured there.

### Upload input files

```bash
# Single file
aws s3 cp mydata.csv s3://<bucket>/input/mydata.csv

# Entire folder
aws s3 cp ./my-inputs/ s3://<bucket>/input/ --recursive

# Upload a model file
aws s3 cp model_weights.pt s3://<bucket>/input/model_weights.pt
```

### Verify the upload

```bash
aws s3 ls s3://<bucket>/input/
```

Expected output:
```
2026-03-22 10:00:00       1024 mydata.csv
2026-03-22 10:00:01    4200000 model_weights.pt
```

> **Note**: Everything under `input/` is downloaded to every job that runs. Keep input focused — large unnecessary files slow down every job.

---

## Step 3 — Prepare Your Job Script

A ready-to-use template is provided at `/fsx/home/user1/s3_pipeline_job.sh`. You can copy and customise it.

```bash
# From the login node
cp /fsx/home/user1/s3_pipeline_job.sh /fsx/home/user1/my_job.sh
nano /fsx/home/user1/my_job.sh
```

### Key sections to customise

The template has a clearly marked processing block. Replace the simulation (`sleep 5`) with your actual workload:

```bash
# ── Step 4: Process data ───────────────────────────────────────────────────────
# REPLACE THIS SECTION with your actual workload, for example:

# Run a Python model
python3 model.py --input "$WORK_DIR/input/" --output "$WORK_DIR/output/"

# Or run an MPI job (submit from sbatch, not here)
# mpirun -np 2 ./my_simulation input.dat

# Or call a shell script
# bash "$WORK_DIR/input/run.sh"
```

### Adjusting Slurm resource requests

Edit the `#SBATCH` lines at the top of the script:

```bash
#SBATCH --job-name=my-model        # Name shown in squeue
#SBATCH --cpus-per-task=2          # CPU cores (t3.micro has 2)
#SBATCH --time=00:30:00            # Max runtime (HH:MM:SS)
#SBATCH --mem=800M                 # Memory (t3.micro has ~900MB usable)
```

---

## Step 4 — Submit the Job

From the login node, submit as your cluster user:

```bash
# Submit as user1
sudo -u user1 sbatch /fsx/home/user1/my_job.sh
```

You will see:
```
Submitted batch job 42
```

The number (`42`) is your **job ID**. Your results will appear at `s3://<bucket>/results/42/`.

---

## Step 5 — Monitor the Job

### Check job status

```bash
squeue
```

| Column | Meaning |
|---|---|
| `PD` | Pending — waiting for a compute node to boot (~8-10 min first time) |
| `CF` | Configuring — compute node is booting and installing software |
| `R` | Running — job is actively executing |
| *(gone)* | Completed or failed |

```bash
# Watch live (refreshes every 5 seconds)
watch -n 5 squeue

# Check which nodes are available
sinfo
```

### Check the job log (live)

The job writes a timestamped log to FSx while running:

```bash
sudo tail -f /fsx/work/user1/job_42.log
```

Example output:
```
[10:05:01] Checking S3 input...
[10:05:02] Found 2 input file(s).
[10:05:02] Downloading input from S3...
[10:05:04] Download complete.
[10:05:04] Processing data on titan-non-prod-compute-0...
[10:05:09] Processing complete.
[10:05:09] Uploading results to s3://<bucket>/results/42/...
[10:05:11] Upload complete.
[10:05:11] Cleaning up FSx work directory...
[10:05:11] Cleanup done.
```

### Check completed job history

```bash
# Summary of all your jobs
sacct --user=user1 --format=JobID,JobName,State,Elapsed,NodeList

# Detailed view of a specific job
sacct -j 42 --format=JobID,State,Elapsed,MaxRSS,NodeList -P
```

---

## Step 6 — Retrieve Your Results

Results are written to S3 automatically when the job completes. The job log shows the exact path.

### List results

```bash
# From your local machine or the login node
aws s3 ls s3://<bucket>/results/42/
```

```
2026-03-22 10:05:11        263 summary.txt
2026-03-22 10:05:11      51200 output.csv
2026-03-22 10:05:11    1048576 predictions.pt
```

### Download results to your machine

```bash
# Single file
aws s3 cp s3://<bucket>/results/42/output.csv ./output.csv

# All results for a job
aws s3 cp s3://<bucket>/results/42/ ./results/job_42/ --recursive
```

### Browse all jobs' results

```bash
aws s3 ls s3://<bucket>/results/
```

```
                           PRE 41/
                           PRE 42/
                           PRE 43/
```

Each folder corresponds to one job ID — results are never overwritten or mixed.

---

## Step 7 — Run Multiple Jobs

You can submit multiple jobs simultaneously. Each gets its own job ID and its own results folder.

```bash
sudo -u user1 sbatch /fsx/home/user1/my_job.sh   # → job 43
sudo -u user1 sbatch /fsx/home/user1/my_job.sh   # → job 44
sudo -u user1 sbatch /fsx/home/user1/my_job.sh   # → job 45

squeue   # all three visible
```

The cluster scales compute nodes automatically (up to the configured maximum). Each job runs in a fully isolated directory `/fsx/work/user1/<job_id>/` that is cleaned up on completion.

---

## Full Example — End to End

```bash
# 1. On your local machine — upload data
aws s3 cp dataset.csv      s3://titan-non-prod-hpc-data-xxxx/input/
aws s3 cp model_config.yml s3://titan-non-prod-hpc-data-xxxx/input/

# 2. SSH to the login node
ssh -i ~/.ssh/titan-hpc ec2-user@<login_ip>

# 3. Submit the job
sudo -u user1 sbatch /fsx/home/user1/s3_pipeline_job.sh
# → Submitted batch job 42

# 4. Watch progress
watch -n 5 squeue
sudo tail -f /fsx/work/user1/job_42.log

# 5. When done — back on your local machine
aws s3 ls s3://titan-non-prod-hpc-data-xxxx/results/42/
aws s3 cp s3://titan-non-prod-hpc-data-xxxx/results/42/ ./results/ --recursive
```

---

## Troubleshooting

### Job stuck in `PD` (Pending) for more than 15 minutes

The compute node is taking too long to boot. Check the Slurm controller log from the head node (ask your admin), or cancel and resubmit:

```bash
scancel 42
sudo -u user1 sbatch /fsx/home/user1/my_job.sh
```

### Job failed — how to debug

```bash
# Check the job log
sudo cat /fsx/work/user1/job_42.log

# Check the error file
sudo cat /fsx/work/user1/job_42.err

# Check Slurm accounting
sacct -j 42 --format=JobID,State,ExitCode,DerivedExitCode -P
```

Common causes:
- **No input files** — check `aws s3 ls s3://<bucket>/input/`
- **Script error** — check the `.err` file for the Python/shell error
- **Out of memory** — reduce `--mem` or upgrade instance type (ask admin)
- **Timeout** — increase `--time` in your job script

### `HPC_BUCKET` not set

If the environment variable is missing on the compute node:

```bash
cat /etc/environment | grep HPC_BUCKET
```

If empty, the node may not have completed its init script. Wait a few minutes and resubmit.

### S3 permission denied

Your user role is already scoped to the cluster bucket. If you see `AccessDenied`, confirm you are using the correct bucket name:

```bash
echo $HPC_BUCKET
```

---

## Reference

### Useful commands

| Command | Purpose |
|---|---|
| `squeue` | Show running and pending jobs |
| `sinfo` | Show node availability |
| `scancel <job_id>` | Cancel a job |
| `sacct --user=user1` | Job history and exit codes |
| `aws s3 ls s3://<bucket>/input/` | List uploaded inputs |
| `aws s3 ls s3://<bucket>/results/` | List all result sets |
| `aws s3 cp s3://<bucket>/results/<id>/ ./ --recursive` | Download results |

### S3 path structure

| Path | Purpose |
|---|---|
| `s3://<bucket>/input/` | Upload your data here before submitting |
| `s3://<bucket>/results/<job_id>/` | Job output — one folder per job |

### FSx path structure (temporary, cleaned after job)

| Path | Purpose |
|---|---|
| `/fsx/work/<user>/<job_id>/input/` | Downloaded S3 input |
| `/fsx/work/<user>/<job_id>/output/` | Processed output (uploaded then deleted) |
| `/fsx/work/<user>/job_<id>.log` | Job log — persists after job |
| `/fsx/home/<user>/` | Your scripts and config |
