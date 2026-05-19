# Titan HPC — Test Plan for $100 AWS Budget

A pragmatic plan to validate the full stack — login node, head node,
workflow node, GPU compute autoscaling, Snakemake fan-out, and the local
podman UI — while spending **< $20** of the $100 credit per full
deploy → test → destroy cycle.

---

## 1. Cost model

### 1a. Always-on infrastructure (charged while the stack exists)

| Component | Hourly | Daily | Notes |
|---|---|---|---|
| Head node (`t3.medium`) | $0.0416 | $1.00 | required |
| Login node (`t3.small`) | $0.0208 | $0.50 | `enable_login_node` |
| Workflow node (`t3.small`) | $0.0208 | $0.50 | `enable_workflow_node` |
| Aurora Serverless v2 (0.5 ACU min) | $0.06 | $1.44 | scales up under load |
| Valkey Serverless | ~$0.07 | $1.70 | minimum storage tier |
| FSx Lustre SCRATCH_2 (1.2 TiB) | $0.14 | $3.36 | minimum size |
| NAT Gateway | $0.045 | $1.08 | + $0.045/GB egress |
| VPC interface endpoints ×8 | $0.08 | $1.92 | $0.01/hr each |
| ALB | $0.0225 | $0.54 | **disabled by default** in our tfvars |
| **Total always-on (ALB off)** | **~$0.44/hr** | **~$10.50/day** | |

**One full test session** = 1 deploy + 4 hours of testing + destroy ≈ **$2.20**.

### 1b. Per-scenario compute cost (only billed while compute nodes run)

| Scenario | Instance | Duration | Cost |
|---|---|---|---|
| 1. CPU smoke (on workflow node) | already running | 1 min | $0.00 |
| 2. Single GPU smoke (T4) | `g4dn.xlarge` | ~5 min + ~3 min boot | $0.07 |
| 3. Multi-job queue (5×T4) | `g4dn.xlarge` ×5 | ~10 min + boot | $0.30 |
| 4. Snakemake fan-out (5 chunks, T4) | `g4dn.xlarge` ×5 | ~10 min + boot | $0.30 |
| 5. L4 single-GPU smoke | `g6.xlarge` | ~5 min + boot | $0.11 |
| 6. MIG demo (H100, **optional, requires quota**) | `p5.4xlarge` | ~15 min + boot | $4.00 |
| **Total scenarios 1–5** | | | **~$0.78** |
| **Total scenarios 1–6** | | | **~$4.78** |

### 1c. Estimated total per full session

| | Without MIG | With MIG |
|---|---|---|
| Always-on (4 hours) | $1.76 | $1.76 |
| Compute scenarios | $0.78 | $4.78 |
| **Total** | **~$2.54** | **~$6.54** |

**Budget headroom**: you can run **~15 full sessions without MIG** or **~15 sessions including MIG** before exhausting $100. Plenty of room for iteration.

---

## 2. Pre-flight

1. **AWS account** in `us-east-1` with quota for:
   - At least 1 `g4dn.xlarge` (T4)
   - At least 1 `g6.xlarge` (L4) — optional for scenario 5
   - At least 1 `p5.4xlarge` (H100, MIG) — optional for scenario 6; quota requests take 1–7 days

2. **Local tooling**:
   - `terraform` ≥ 1.9, `aws` CLI v2 with Session Manager plugin
   - `podman` + `podman-compose` (or `docker compose`)

3. **Customize `terraform.tfvars`**:
   - Update `ssh_allowed_cidr` to your `/32`
   - Update `admin_email` and the `team_members` list
   - Confirm `enable_alb = false`, `enable_workflow_node = true`

---

## 3. Deploy

```bash
terraform init
terraform apply -var-file=terraform.tfvars

# Save outputs for later commands
terraform output -raw ssm_port_forward_command > /tmp/ssm-fwd.sh
terraform output -raw admin_temp_password_command > /tmp/admin-pwd.sh
terraform output -raw workflow_node_ssm_command > /tmp/workflow-ssm.sh

# Upload the Snakemake demo so the workflow node can stage it from S3
BUCKET=$(terraform output -raw s3_data_bucket)
aws s3 sync examples/snakemake-demo/ "s3://$BUCKET/platform/examples/snakemake-demo/"
```

Wait ~6 minutes for the head node user_data to finish (Slurm build, Aurora wait, jobui boot). Verify by SSM'ing into the head node:

```bash
aws ssm start-session --target $(terraform output -raw head_node_instance_id)
# On the head node:
sudo tail -f /var/log/titan-head-bootstrap.log    # wait for "bootstrap complete"
sinfo                                              # all partitions should show
docker ps                                          # jobui-backend + jobui-nginx running
```

---

## 4. Start the local UI

```bash
# Terminal 1 — SSM tunnel to head node :80 (leave running)
bash /tmp/ssm-fwd.sh

# Terminal 2 — local UI
cd local-ui
podman-compose up --build
```

Open <http://localhost:3000>. Get admin temp password from `bash /tmp/admin-pwd.sh`. Sign in as `admin` (the username derived from the email's local-part), change password when prompted.

---

## 5. Test scenarios

### Scenario 1 — CPU smoke (validates workflow node + Slurm)

**Goal**: confirm the workflow node has Slurm client access and can talk to slurmctld.

```bash
bash /tmp/workflow-ssm.sh
# On the workflow node:
sinfo                          # should list gpu-t4 and gpu-l4 partitions
sudo -u ec2-user squeue        # empty queue
echo '#!/bin/bash
hostname; sleep 3; echo done' > /tmp/cpu-smoke.sh
chmod +x /tmp/cpu-smoke.sh
# Submit to a GPU partition (we have no CPU partition by default) with --gres=gpu:0
sbatch --partition=gpu-t4 --time=00:05:00 --gres=gpu:t4:0 /tmp/cpu-smoke.sh
squeue
```

**Cost**: $0. **Pass criteria**: `squeue` shows the job; `sacct -j <id>` shows `COMPLETED` within ~5 minutes.

> Note: without a dedicated CPU partition, this still allocates a T4 node. To add a real CPU partition, extend `gpu_family_spec` with a `cpu` family (gpus_per_node=0) — left as future work.

### Scenario 2 — Single GPU smoke via UI (validates end-to-end)

1. In the UI, click **Submit job**
2. Pick **T4** GPU family
3. Upload `examples/snakemake-demo/input/sample.fasta` as input
4. Select any registered model (or register a smoke one via Admin → register model with `ecr_uri = nvidia/cuda:12.2.0-base-ubuntu22.04`)
5. Submit. Watch the Jobs page — should go submitted → pending → running → completed in ~5–8 minutes (boot + brief inference + upload).
6. Open the job detail page. Verify `log_tail` shows `nvidia-smi` output and result files appear.

**Cost**: ~$0.07. **Pass criteria**: result files in S3 under `results/<slurm_job_id>/`; log archived to `logs/<username>/<slurm_job_id>/slurm.log`.

### Scenario 3 — Multi-job queue (validates fairshare + autoscale)

Submit 5 T4 jobs in quick succession via the UI (same input, same model). Watch `squeue` on the workflow node.

```bash
# On workflow node:
watch -n 2 'squeue; echo; sinfo'
```

**Pass criteria**:
- 1st job picks up an idle node (or waits ~3 min for boot)
- Subsequent jobs trigger `resume-node.sh` to launch more T4s up to `gpu_max_nodes.t4 = 4`
- After all jobs finish, `sinfo` shows nodes returning to idle, then DOWN after `SuspendTime=120s`
- `/var/log/slurm/resume.log` on head node shows successful `RunInstances` calls

**Cost**: ~$0.30.

### Scenario 4 — Snakemake fan-out (the headline workflow test)

```bash
bash /tmp/workflow-ssm.sh
# On workflow node:
cd /fsx/shared/snakemake-demo
sudo -u ec2-user snakemake --profile slurm --jobs 5
```

**Pass criteria**:
- 5 inference jobs spawn in parallel
- Each chunk produces `scratch/results/chunk-NNN.json` with a `gpus_seen` field listing the GPU
- `merge` rule combines them into `results/summary.json`
- Total wall time: ~6–12 minutes depending on warm capacity

**Cost**: ~$0.30 (often less if nodes from Scenario 3 are still warm).

### Scenario 5 — L4 family routing (optional)

Repeat Scenario 2 but pick **L4** as the GPU family. Verifies multi-family partition routing and that the per-family `SuspendTime` from `gpu_family_spec` is respected.

**Cost**: ~$0.11.

### Scenario 6 — H100 MIG demo (optional, gated on quota)

This is the only scenario that requires extra setup beyond the deployed stack — Slurm MIG GRES is not auto-configured by the bootstrap. Run it manually to demonstrate the concept; full Slurm-MIG integration is documented as future work.

```bash
# 1. Set gpu_families_enabled to include "h100-1x" and apply
#    terraform apply -var='gpu_families_enabled=["t4","l4","h100-1x"]'

# 2. Provision an H100 node via scontrol on the head node
aws ssm start-session --target $(terraform output -raw head_node_instance_id)
sudo /opt/slurm/bin/scontrol update NodeName=h100-1x-1 State=RESUME

# 3. Wait for boot (~5-8 min), then SSM into the compute node
aws ec2 describe-instances --filters "Name=tag:Name,Values=titan-non-prod-compute-h100-1x" \
    --query 'Reservations[].Instances[].InstanceId' --output text
aws ssm start-session --target <h100-instance-id>

# 4. On the H100 node: enable MIG mode and create 7 × 1g.10gb slices
sudo nvidia-smi -mig 1
sudo nvidia-smi mig -cgi 1g.10gb,1g.10gb,1g.10gb,1g.10gb,1g.10gb,1g.10gb,1g.10gb -C
nvidia-smi -L     # should now show 7 MIG-UUID lines

# 5. Smoke-test inference inside one slice
sudo docker run --rm \
    -e NVIDIA_VISIBLE_DEVICES=$(nvidia-smi -L | head -1 | grep -oP 'MIG-[a-f0-9-]+') \
    nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
```

**Cost**: ~$4 (p5.4xlarge × ~15 min including boot). Only run if you have H100 quota.

### Scenario 7 — Failure paths (free; runs against existing jobs)

- **Upload abort**: in the UI, start an upload of a large file, click cancel during upload. Verify `aborted` row in `uploads` table and no orphaned S3 multipart upload (`aws s3api list-multipart-uploads --bucket $BUCKET`).
- **`must_change_password`**: log in as the seeded `bob` user with the admin temp password — should be force-redirected to `/change-password`. Try to call `/api/jobs` directly with `bob`'s token — should get 403.
- **Health check**: stop the jobui backend container on the head node (`docker stop jobui-backend`), curl `localhost:8080/api/health` from the laptop (via SSM tunnel) — should return 503 with `aurora: ok, slurm: error`.

**Cost**: $0.

---

## 6. Teardown (critical for staying under budget)

```bash
bash scripts/destroy.sh terraform.tfvars
```

This terminates any compute nodes still running, aborts S3 multipart uploads, then `terraform destroy`. **Always run this when you finish for the day** — leaving the stack up costs ~$10/day.

---

## 7. Recommended cadence

- **Session 1** (~$5): Deploy → Scenarios 1, 2, 3, 4, 7 → destroy. Validates everything except L4 and MIG.
- **Session 2** (~$3): Deploy → Scenarios 2 (T4), 5 (L4), 4 (Snakemake) → destroy. Validates multi-family.
- **Session 3** (~$8, if you have H100 quota): Deploy with `h100-1x` enabled → Scenarios 2 + 6 → destroy.

Total: **~$16** of $100 spent on three thorough sessions, leaving $84 for ad-hoc work, model staging, or longer development.

---

## 8. Known gaps / future work (documented, not blocking)

1. **No native CPU partition** — Scenario 1 piggybacks on a T4 node with `--gres=gpu:t4:0`. To add a real CPU compute fleet, extend `gpu_family_spec` with `cpu = { gpus_per_node = 0, ... }` and special-case it in `compute-fleet/main.tf` (use AL2023 AMI, not DLAMI).
2. **MIG not Slurm-integrated** — Scenario 6 is manual. Production setup requires adding MIG slices as GRES in `gres.conf` and a separate `h100-mig` family in `gpu_family_spec`.
3. **No GPU/queue telemetry** — Slurm exporter, DCGM exporter, and Grafana are not deployed. Use `sinfo`, `squeue`, `nvidia-smi` directly via SSM.
4. **Frontend dead code** — `pages/SubmitJob.jsx`, `pages/Dashboard.jsx`, `api/*.js`, `hooks/*.js`, `components/*.jsx` are leftovers from an earlier implementation. Safe to delete; not wired into `App.jsx`.

---

## 9. Quick reference

| What | Command |
|---|---|
| SSM into head node | `aws ssm start-session --target $(terraform output -raw head_node_instance_id)` |
| SSM into workflow node | `bash /tmp/workflow-ssm.sh` |
| Start SSM tunnel for UI | `bash /tmp/ssm-fwd.sh` |
| Get admin temp password | `bash /tmp/admin-pwd.sh` |
| Sinfo / squeue / sacct | run on head or workflow node |
| Tail bootstrap log | `sudo tail -f /var/log/titan-head-bootstrap.log` (head node) |
| Tail compute boot log | `sudo tail -f /var/log/titan-bootstrap.log` (compute node) |
| Destroy everything | `bash scripts/destroy.sh terraform.tfvars` |
