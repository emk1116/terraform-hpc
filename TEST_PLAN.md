# Titan HPC — Test Plan for $100 AWS Budget

Validates the full stack — login node, head node, workflow node, GPU compute
autoscaling, and Snakemake fan-out — while spending **< $15** of the $100
credit per full deploy → test → destroy cycle.

The stack is **pure HPC** (no web UI). Users SSM into the login node and
run `sbatch` / `snakemake` directly. The optional jobui in
`jobui/` is out of scope here — it will ship later as a Fargate service.

---

## 1. Cost model

### 1a. Always-on infrastructure

| Component | Hourly | Daily |
|---|---|---|
| Head node `t3.small` (slurmctld + slurmdbd) | $0.0208 | $0.50 |
| Login node `t3.small` (Slurm CLI + FSx mount) | $0.0208 | $0.50 |
| Workflow node `t3.small` | $0.0208 | $0.50 |
| Aurora Serverless v2 (0.5 ACU min) | $0.06 | $1.44 |
| FSx Lustre SCRATCH_2 (1.2 TiB) | $0.14 | $3.36 |
| NAT Gateway | $0.045 | $1.08 |
| VPC interface endpoints ×8 | $0.08 | $1.92 |
| **Total always-on** | **~$0.35/hr** | **~$8.50/day** |

**One full test session** = 1 deploy + 4 hours of testing + destroy ≈ **$1.80**.

### 1b. Per-scenario compute cost

| Scenario | Instance | Duration | Cost |
|---|---|---|---|
| 1. CPU job (real `cpu` partition) | `c5.large` | ~3 min + ~2 min boot | $0.01 |
| 2. Single T4 GPU job | `g4dn.xlarge` | ~5 min + ~3 min boot | $0.07 |
| 3. 5×T4 queue test | `g4dn.xlarge` ×5 | ~10 min + boot | $0.30 |
| 4. Snakemake fan-out (5 chunks, T4) | `g4dn.xlarge` ×5 | ~10 min + boot | $0.30 |
| 5. L4 single-GPU smoke | `g6.xlarge` | ~5 min + boot | $0.11 |
| 6. Telemetry check (Prometheus) | already running | 5 min | $0.00 |
| 7. H100 MIG (7 slices, requires quota) | `p5.4xlarge` | ~15 min + boot | $4.00 |
| **Total scenarios 1–6** | | | **~$0.79** |

### 1c. Per session

| | Without MIG | With MIG |
|---|---|---|
| Always-on (4 hours) | $1.42 | $1.42 |
| Compute scenarios | $0.78 | $4.78 |
| **Total** | **~$2.20** | **~$6.20** |

**Budget headroom**: ~45 sessions without MIG, or ~15 sessions with MIG.

---

## 2. Pre-flight

1. AWS account in `us-east-1` with quota for at least 1 `g4dn.xlarge` (T4) and 1 `g6.xlarge` (L4). H100 quota only needed for Scenario 6.
2. Local tooling: `terraform` ≥ 1.9, `aws` CLI v2 with Session Manager plugin.
3. Customize `terraform.tfvars`:
   - `ssh_allowed_cidr = "<your-ip>/32"`
   - `admin_email = "you@example.com"`

---

## 3. Deploy

```bash
ssh-keygen -t ed25519 -f ~/.ssh/titan-hpc -C "titan-hpc" -N ""

terraform init
terraform apply -var-file=terraform.tfvars

# Save commands for later use
terraform output -raw login_node_ssm_command    > /tmp/login-ssm.sh
terraform output -raw workflow_node_ssm_command > /tmp/workflow-ssm.sh
terraform output -raw head_node_ssm_command     > /tmp/head-ssm.sh

# Upload the Snakemake demo so the workflow / login nodes can stage it
BUCKET=$(terraform output -raw s3_data_bucket)
aws s3 sync examples/snakemake-demo/ "s3://$BUCKET/platform/examples/snakemake-demo/"
```

Wait ~10–15 min for the head node to finish building Slurm from source and the login/workflow nodes to bootstrap their Slurm client. Verify:

```bash
# Admin sanity check on the head node
bash /tmp/head-ssm.sh
# On head node:
sudo tail -50 /var/log/titan-head-bootstrap.log    # should end with "bootstrap complete"
systemctl status slurmctld slurmdbd                 # both active
sinfo                                                # all partitions show
exit

# User sanity check on the login node
bash /tmp/login-ssm.sh
# On login node:
sudo tail -20 /var/log/titan-login-bootstrap.log   # "login node ready"
sinfo                                               # same partition listing
squeue                                              # empty
```

---

## 4. Test scenarios

### Scenario 1 — CPU job (real `cpu` partition)

Validates the login node's Slurm client, the CPU partition (c5.large on
AL2023, no GPU), and autoscaling of a non-GPU node.

```bash
bash /tmp/login-ssm.sh
# On login node:
sinfo                     # should list: cpu, gpu-t4, gpu-l4 partitions

cat > /tmp/cpu-smoke.sh <<'EOF'
#!/bin/bash
#SBATCH --job-name=cpu-smoke
#SBATCH --partition=cpu
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=2
#SBATCH --output=/fsx/work/%u/%j/out.log
mkdir -p /fsx/work/$USER/$SLURM_JOB_ID
echo "hostname: $(hostname)"
echo "cpus: $(nproc)"
echo "fsx mount: $(mountpoint /fsx)"
echo "s3 reachable: $(aws s3 ls s3:// 2>&1 | head -1)"
EOF
sbatch /tmp/cpu-smoke.sh
squeue -u $USER
```

**Cost**: ~$0.01 (one c5.large boot). **Pass**: `sacct -j <id>` shows `COMPLETED`; `/fsx/work/$USER/<id>/out.log` shows 2 CPUs, no GPU. A `cpu-1` node appears in `sinfo` then suspends after 300s idle.

### Scenario 2 — Single GPU job (T4)

```bash
bash /tmp/login-ssm.sh
# On login node — define a reusable GPU smoke script:
cat > /tmp/gpu-smoke.sh <<'EOF'
#!/bin/bash
#SBATCH --job-name=gpu-smoke
#SBATCH --partition=gpu-t4
#SBATCH --time=00:05:00
#SBATCH --gres=gpu:t4:1
#SBATCH --output=/fsx/work/%u/%j/out.log
mkdir -p /fsx/work/$USER/$SLURM_JOB_ID
echo "hostname: $(hostname)"
nvidia-smi
EOF
sbatch /tmp/gpu-smoke.sh
squeue -u $USER
```

**Cost**: ~$0.07. **Pass**: `sacct -j <id>` shows `COMPLETED`; out.log shows the T4. For a real inference run with a container, see `jobs/inference_job.sh.tpl`.

### Scenario 3 — Multi-job queue (5×T4) — autoscale stress

```bash
bash /tmp/login-ssm.sh
# On login node:
for i in 1 2 3 4 5; do
    sbatch /tmp/gpu-smoke.sh
done
watch -n 2 'squeue; echo; sinfo'
```

**Pass**: Slurm spins up nodes up to `gpu_max_nodes.t4 = 4` (1 queued); all complete; `sinfo` shows nodes returning to idle, then DOWN after `SuspendTime=120s`. **Cost**: ~$0.30.

### Scenario 4 — Snakemake fan-out (headline workflow test)

```bash
bash /tmp/workflow-ssm.sh
# On workflow node:
cd /fsx/shared/snakemake-demo
snakemake --profile slurm --jobs 5
```

**Pass**: 5 inference jobs spawn in parallel; each produces `scratch/results/chunk-NNN.json`; `merge` rule produces `results/summary.json`. **Cost**: ~$0.30.

> Snakemake also runs on the login node (preinstalled) — the workflow node
> is just for isolation when DAGs are long-running. Either node is a
> first-class place to launch workflows; try both:
> ```bash
> bash /tmp/login-ssm.sh
> cd /fsx/shared/snakemake-demo && snakemake --profile slurm --jobs 5
> ```

### Scenario 5 — L4 family (multi-family routing)

```bash
bash /tmp/login-ssm.sh
# On login node — submit to gpu-l4 partition
sed 's/gpu-t4/gpu-l4/; s/gpu:t4:1/gpu:l4:1/' /tmp/gpu-smoke.sh > /tmp/l4-smoke.sh
sbatch /tmp/l4-smoke.sh
```

**Pass**: `resume-node.sh` launches a `g6.xlarge` in the L4 partition. **Cost**: ~$0.11.

### Scenario 6 — Telemetry (free)

```bash
# From your laptop — port-forward Prometheus off the head node
$(terraform output -raw prometheus_port_forward_command)
# Open http://localhost:9090 and run queries:
#   up                          → slurm + dcgm targets healthy
#   slurm_nodes_idle            → idle node count
#   slurm_queue_pending         → pending jobs
#   DCGM_FI_DEV_GPU_UTIL        → live GPU utilization (when a GPU job runs)
```

Run this while Scenario 3 is in flight to watch GPU utilization climb.
**Pass**: Prometheus `/targets` shows the slurm-exporter (`localhost:8080`) UP and one DCGM target per running GPU node.

### Scenario 7 — H100 MIG (requires H100 quota)

```bash
# 1. Enable the h100-mig family and apply
terraform apply -var='gpu_families_enabled=["cpu","t4","l4","h100-mig"]' -var-file=terraform.tfvars

# 2. On the login node, submit to the MIG partition (1 slice)
bash /tmp/login-ssm.sh
cat > /tmp/mig-smoke.sh <<'EOF'
#!/bin/bash
#SBATCH --job-name=mig-smoke
#SBATCH --partition=gpu-h100-mig
#SBATCH --time=00:10:00
#SBATCH --gres=gpu:1g.10gb:1
#SBATCH --output=/fsx/work/%u/%j/out.log
mkdir -p /fsx/work/$USER/$SLURM_JOB_ID
nvidia-smi -L     # should show one MIG device
EOF
sbatch /tmp/mig-smoke.sh
```

The compute node auto-enables MIG and creates 7×1g.10gb slices at boot. Submit up to 7 concurrent jobs to one p5.4xlarge — they share the GPU via MIG.
**Pass**: the job lands on a single MIG slice; `nvidia-smi -L` inside the job shows one `MIG ... 1g.10gb` device. **Cost**: ~$4 (p5.4xlarge × ~15 min). See §7 Known gaps — validate the GRES profile name on real hardware.

### Scenario 8 — Failure paths (free)

- **Cancelled job**: `scancel <id>` mid-run. Verify scratch cleanup cron on head node removes the orphaned `/fsx/work/$USER/<id>` dir (run manually: `sudo /etc/cron.daily/titan-scratch-cleanup`).
- **Bad partition**: `sbatch --partition=nonexistent /tmp/cpu-smoke.sh` — should fail at submit time with a clear error.
- **Capacity exhausted**: queue 5 jobs while `gpu_max_nodes.t4 = 4`; the 5th stays in `PD` (Pending) with reason `Resources`.

---

## 5. Teardown

```bash
bash scripts/destroy.sh terraform.tfvars
```

This terminates any compute nodes still running and runs `terraform destroy`. **Always run this when you finish for the day** — leaving the stack up costs ~$8.50/day.

---

## 6. Recommended cadence

- **Session 1** (~$3): Deploy → Scenarios 1 (CPU), 2 (T4), 3 (queue), 4 (Snakemake), 6 (telemetry), 8 (failures) → destroy. Validates everything except L4 and MIG.
- **Session 2** (~$2): Deploy → Scenarios 2 (T4), 5 (L4), 4 (Snakemake) → destroy. Validates multi-family.
- **Session 3** (~$8, if H100 quota): Deploy with `h100-mig` enabled → Scenario 7 (MIG) → destroy.

Total: **~$13** of $100 spent on three thorough sessions, leaving $87 for ad-hoc work or longer development.

---

## 7. Known gaps

1. **MIG profile naming is experimental** — the `h100-mig` family enables MIG and creates 7×1g.10gb slices at boot, and Slurm is told `gpu:1g.10gb:7`. This needs validation on real H100 hardware to confirm the GRES type Slurm's NVML auto-detect reports matches `1g.10gb`. If it mismatches, adjust the type in `modules/head-node/main.tf` (`slurm_nodes` local).
2. **No bundled Grafana** — Prometheus is deployed on the head node but there's no Grafana. Point your own Grafana (Cloud free tier or local) at the SSM-forwarded `:9090` and import dashboard IDs 4323 (Slurm) + 12239 (DCGM).
3. **No web UI** — by design. The `jobui/` directory is reference code for a future Fargate deployment.

---

## 8. Quick reference

| What | Command |
|---|---|
| Login node SSM | `bash /tmp/login-ssm.sh` |
| Workflow node SSM | `bash /tmp/workflow-ssm.sh` |
| Head node SSM (admin) | `bash /tmp/head-ssm.sh` |
| Sinfo / squeue / sacct | run on login or workflow node |
| Tail head bootstrap log | `sudo tail -f /var/log/titan-head-bootstrap.log` (head node) |
| Tail login bootstrap log | `sudo tail -f /var/log/titan-login-bootstrap.log` (login node) |
| Destroy everything | `bash scripts/destroy.sh terraform.tfvars` |
