# Titan HPC — Test Plan for $100 AWS Budget

Validates the full stack — login node, head node, workflow node, GPU compute
autoscaling, and Snakemake fan-out — while spending **< $15** of the $100
credit per full deploy → test → destroy cycle.

The stack is **pure HPC** (no web UI). Users SSM into the login node and
run `sbatch` / `snakemake` / `nextflow` directly. The optional jobui in
`jobui/` is out of scope here — it will ship later as a Fargate service.

---

## 1. Cost model

### 1a. Always-on infrastructure

| Component | Hourly | Daily |
|---|---|---|
| Head node `t3.small` (slurmctld + slurmdbd) | $0.0208 | $0.50 |
| Login node `t3.small` (Slurm CLI + FSx mount) | $0.0208 | $0.50 |
| Workflow node `t3.small` (optional) | $0.0208 | $0.50 |
| Aurora Serverless v2 (0.5 ACU min) | $0.06 | $1.44 |
| FSx Lustre SCRATCH_2 (1.2 TiB) | $0.14 | $3.36 |
| NAT Gateway | $0.045 | $1.08 |
| VPC interface endpoints ×8 | $0.08 | $1.92 |
| **Total always-on** | **~$0.35/hr** | **~$8.50/day** |

**One full test session** = 1 deploy + 4 hours of testing + destroy ≈ **$1.80**.

### 1b. Per-scenario compute cost

| Scenario | Instance | Duration | Cost |
|---|---|---|---|
| 1. Cluster smoke (CLI from login node) | already running | 2 min | $0.00 |
| 2. Single T4 GPU job | `g4dn.xlarge` | ~5 min + ~3 min boot | $0.07 |
| 3. 5×T4 queue test | `g4dn.xlarge` ×5 | ~10 min + boot | $0.30 |
| 4. Snakemake fan-out (5 chunks, T4) | `g4dn.xlarge` ×5 | ~10 min + boot | $0.30 |
| 5. L4 single-GPU smoke | `g6.xlarge` | ~5 min + boot | $0.11 |
| 6. MIG demo (H100, optional, requires quota) | `p5.4xlarge` | ~15 min + boot | $4.00 |
| **Total scenarios 1–5** | | | **~$0.78** |

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

### Scenario 1 — Cluster smoke (free)

Validates login node has a working Slurm client and can reach slurmctld.

```bash
bash /tmp/login-ssm.sh
# On login node:
sinfo
sbatch jobs/fsx_smoke_test.sh    # if you've staged it, or:

cat > /tmp/cluster-smoke.sh <<'EOF'
#!/bin/bash
#SBATCH --job-name=smoke
#SBATCH --partition=gpu-t4
#SBATCH --time=00:05:00
#SBATCH --gres=gpu:t4:1
#SBATCH --output=/fsx/work/%u/%j/out.log
mkdir -p /fsx/work/$USER/$SLURM_JOB_ID
echo "hostname: $(hostname)"
nvidia-smi
echo "fsx mount: $(mountpoint /fsx)"
echo "s3 reachable: $(aws s3 ls s3:// 2>&1 | head -1)"
EOF
sbatch /tmp/cluster-smoke.sh
squeue -u $USER
```

**Cost**: ~$0.07 (one T4 boot). **Pass**: `sacct -j <id>` shows `COMPLETED`; `/fsx/work/$USER/<id>/out.log` shows GPU info.

### Scenario 2 — Single GPU inference (T4)

Stage an input file to S3, run an inference container against it. See `jobs/inference_job.sh.tpl` as the reference. **Cost**: ~$0.07.

### Scenario 3 — Multi-job queue (5×T4) — autoscale stress

```bash
bash /tmp/login-ssm.sh
# On login node:
for i in 1 2 3 4 5; do
    sbatch /tmp/cluster-smoke.sh
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

> Snakemake can also run on the login node — the workflow node is just for
> isolation when DAGs are long-running. Try both:
> ```bash
> bash /tmp/login-ssm.sh
> cd /fsx/shared/snakemake-demo && snakemake --profile slurm --jobs 5
> ```

### Scenario 5 — L4 family (multi-family routing)

```bash
bash /tmp/login-ssm.sh
# On login node — submit to gpu-l4 partition
sed 's/gpu-t4/gpu-l4/; s/gpu:t4:1/gpu:l4:1/' /tmp/cluster-smoke.sh > /tmp/l4-smoke.sh
sbatch /tmp/l4-smoke.sh
```

**Pass**: `resume-node.sh` launches a `g6.xlarge` in the L4 partition. **Cost**: ~$0.11.

### Scenario 6 — H100 MIG demo (optional, requires quota)

Same as before — but uses Slurm `scontrol resume` to power up the H100 node,
then SSM into the compute node and manually enable MIG. See repository
README §Roadmap for the future automated MIG GRES integration. **Cost**: ~$4 (p5.4xlarge × ~15 min).

### Scenario 7 — Failure paths (free)

- **Cancelled job**: `scancel <id>` mid-run. Verify scratch cleanup cron on head node removes the orphaned `/fsx/work/$USER/<id>` dir after 7 days (or run the cron manually: `sudo /etc/cron.daily/titan-scratch-cleanup`).
- **Bad partition**: `sbatch --partition=nonexistent /tmp/cluster-smoke.sh` — should fail at submit time with a clear error.
- **Capacity exhausted**: queue 5 jobs while `gpu_max_nodes.t4 = 4`; the 5th stays in `PD` (Pending) with reason `Resources`.

---

## 5. Teardown

```bash
bash scripts/destroy.sh terraform.tfvars
```

This terminates any compute nodes still running and runs `terraform destroy`. **Always run this when you finish for the day** — leaving the stack up costs ~$8.50/day.

---

## 6. Recommended cadence

- **Session 1** (~$3): Deploy → Scenarios 1, 2, 3, 4, 7 → destroy. Validates everything except L4 and MIG.
- **Session 2** (~$2): Deploy → Scenarios 2 (T4), 5 (L4), 4 (Snakemake) → destroy. Validates multi-family.
- **Session 3** (~$8, if H100 quota): Deploy with `h100-1x` enabled → Scenarios 2 + 6 → destroy.

Total: **~$13** of $100 spent on three thorough sessions, leaving $87 for ad-hoc work or longer development.

---

## 7. Known gaps

1. **No native CPU partition** — Scenario 1 uses a T4 node. To add a real CPU partition, extend `gpu_family_spec` with a `cpu` family and special-case it in `compute-fleet/main.tf` (use AL2023 AMI, not DLAMI).
2. **MIG not Slurm-integrated** — Scenario 6 is manual.
3. **No GPU/queue telemetry** — Slurm exporter, DCGM exporter, and Grafana are not deployed. Use `sinfo`, `squeue`, `nvidia-smi` directly via SSM.
4. **No web UI** — by design. The `jobui/` directory is reference code for a future Fargate deployment.

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
