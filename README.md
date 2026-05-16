# Titan HPC — GPU Inference Platform

Production-grade HPC cluster on AWS for **team-scale GPU inference**. One team gets one cluster. Team members log into a web UI, upload input files (up to 5 GB), pick a GPU type and a model from dropdowns, click submit. Slurm spins up the matching GPU instance, pulls the model container from ECR, runs inference against weights staged on FSx Lustre, uploads results back to S3, and terminates the node when idle.

Enhanced fork of [`emk1116/terraform-hpc`](https://github.com/emk1116/terraform-hpc) — same Slurm-on-AWS pattern, significantly expanded for containerized GPU inference at team scale with H100-class workloads.

## What's different from the base repo

| Area | Base repo | This repo |
|---|---|---|
| GPU support | CPU-only `t3.micro` | 6 partitions: T4, A10G, L4, A100, 1×H100, 8×H100 |
| Database | MariaDB on head node | **Aurora Serverless v2 MySQL** (single AZ) |
| Cache | None | **Valkey Serverless** (ElastiCache) |
| Head node placement | Public | **Private behind ALB** |
| Upload limit | 500 MB via nginx | **Direct-to-S3 multipart**, 5 GB+ |
| Models | N/A | Catalog in Aurora with GPU-memory filtering |
| Users | Hardcoded user1/user2 | Team members table with roles, budgets, H100 approval |
| Container runtime | None | Docker + NVIDIA Container Toolkit + s5cmd on DLAMI |
| Cost controls | None | Per-user monthly budget enforced at submit |
| Capacity handling | Single AZ, fail-on-missing | Multi-AZ retry for H100 InsufficientInstanceCapacity |

## Architecture

See `docs/ARCHITECTURE.md` for the full diagram and data flow. Summary:

- **Network**: VPC with public subnets (ALB + login node) and private subnets (head node, Aurora, Valkey, compute). Default deployment AZ is **us-east-1f**.
- **Head node** (private): runs `slurmctld`, `slurmdbd`, nginx, FastAPI, React UI — all in Docker Compose. Reachable only via ALB (HTTPS) or SSM Session Manager.
- **Aurora Serverless v2 MySQL** (private, single AZ): two databases on one cluster — `slurm_acct_db` owned by slurmdbd, `jobui` owned by the app.
- **Valkey Serverless** (private): session tokens, rate limiting, queue status cache.
- **FSx Lustre SCRATCH_2 2.4 TB** (same AZ as compute): `/fsx/models/<m>/` holds pre-staged weights, `/fsx/work/<u>/<job>/` is per-job scratch.
- **GPU compute fleet**: 6 launch templates (one per GPU family), DLAMI base, s5cmd + Docker + NVIDIA toolkit preinstalled. Autoscales 0→N via Slurm's Resume/SuspendProgram.
- **S3**: data bucket with per-user prefixes, versioned, encrypted, no public access.
- **ECR**: per-team repositories for model images.

## Submit flow

1. Browser → ALB (HTTPS) → FastAPI: `POST /api/uploads/init` returns presigned S3 multipart URLs
2. Browser uploads 5 GB file directly to S3 in 8 MB chunks, in parallel
3. Browser → FastAPI: `POST /api/uploads/complete` — multipart merge
4. User picks GPU family + model + runtime → FastAPI validates budget in Aurora, estimates cost, writes `jobs` row, shells out to `sbatch`
5. Slurm queues job; `ResumeProgram` picks launch template by GPU family and calls `ec2:RunInstances`
6. For H100: retries across AZs on `InsufficientInstanceCapacity`
7. Compute node boots from DLAMI, mounts FSx, registers with Slurm
8. Job script runs: `s5cmd cp` S3→FSx → `docker run --gpus all` with weights from `/fsx/models/<m>` → `s5cmd cp` FSx→S3 → cleanup `/fsx/work/<u>/<job>`
9. `slurmdbd` flushes accounting to Aurora `slurm_acct_db`
10. `SuspendProgram` terminates node after `SuspendTime` idle
11. Nightly cron rolls up per-user spend into `jobui.monthly_spend`

## Prerequisites

- Terraform ≥ 1.9
- AWS CLI v2 configured with admin credentials
- A registered domain (or ACM certificate in us-east-1) for the ALB HTTPS listener
- **EC2 quota for the GPU families you plan to use** — request ahead of time:
  - `Running On-Demand G and VT instances` (T4/A10G/L4) — default often 0, request ≥ 96 vCPU
  - `Running On-Demand P instances` (A100/H100) — default 0. Must request. Expect 1–2 weeks for H100 approval in us-east-1f.
- S3 bucket for Terraform state (bootstrap separately)

## Quick start

```bash
# 1. Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/titan-hpc -C "titan-hpc"

# 2. Create your team's tfvars
cp non-prod.tfvars.example team-alpha.tfvars
# Edit: team_name, admin_email, users[], ssh_allowed_cidr, acm_certificate_arn

# 3. Init Terraform
terraform init \
  -backend-config="bucket=terraform-hpc-state-<account-id>" \
  -backend-config="key=teams/team-alpha/terraform.tfstate" \
  -backend-config="region=us-east-1"

# 4. Plan and apply (expect ~20 min; FSx is the long pole)
terraform apply -var-file=team-alpha.tfvars

# 5. Get the ALB URL and admin credentials
terraform output jobui_url
terraform output admin_temp_password  # Change on first login

# 6. Register a model and stage its weights — see docs/ADDING_MODELS.md

# Destroy when done
bash scripts/destroy.sh
```

## Per-team cost baseline (us-east-1)

| Resource | Cost |
|---|---|
| Aurora Serverless v2 (0.5 ACU min) | ~$44/mo |
| Valkey Serverless (1 GB min) | ~$70/mo |
| ALB | ~$22/mo |
| Head node (t3.medium) | ~$30/mo |
| FSx Lustre SCRATCH_2 2.4 TB | ~$680/mo |
| NAT Gateway | ~$32/mo |
| **Baseline** | **~$880/mo** |

Plus GPU-hour costs as used. See `docs/COSTS.md`.

## Documentation

- `docs/ARCHITECTURE.md` — full architecture diagram and data flow
- `docs/DEPLOYMENT.md` — end-to-end deployment walkthrough
- `docs/SECURITY.md` — IAM boundaries, network segmentation, secrets handling
- `docs/COSTS.md` — detailed cost model + guardrail configuration
- `docs/GPU_GUIDE.md` — GPU family selection, quotas, capacity strategy
- `docs/ADDING_MODELS.md` — register a new model, stage weights
- `docs/TROUBLESHOOTING.md` — common failure modes

## License

MIT
