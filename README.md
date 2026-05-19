# Titan HPC — GPU Inference Platform

Production-grade HPC cluster on AWS for **team-scale GPU inference and workflow
execution**. One team gets one cluster. Team members log into a web UI, upload
input files (up to 10 GB), pick a GPU type and a model, click submit. Slurm
spins up the matching GPU instance, pulls the model container from ECR, runs
inference against weights staged on FSx Lustre, uploads results back to S3,
and terminates the node when idle. A dedicated **workflow node** runs
Snakemake / Nextflow pipelines that fan out into the same Slurm cluster.

Enhanced fork of [`emk1116/terraform-hpc`](https://github.com/emk1116/terraform-hpc) — same Slurm-on-AWS pattern, significantly expanded for containerized GPU inference at team scale with H100-class workloads and DAG workflows.

## Topology (ALB-less by default)

```
┌───────────────┐  aws ssm   ┌──────────────────────────────────────────────┐
│  Your laptop  │  port-fwd  │  AWS VPC (private)                           │
│               │ ─────────► │                                              │
│ podman UI:3000│            │  head node (slurmctld, slurmdbd, jobui)      │
│  └─/api/* ────┘            │     │                                        │
│                            │     ├── workflow node (Snakemake, sbatch)    │
│                            │     ├── login node (SSH, optional)           │
│                            │     ├── Aurora Serverless v2 (mysql)         │
│                            │     ├── Valkey Serverless (cache)            │
│                            │     ├── FSx Lustre 1.2 TiB (/fsx)            │
│                            │     └── compute fleet (T4/L4/A10G/A100/H100) │
│                            │             └── autoscaled by Slurm          │
└───────────────┘            └──────────────────────────────────────────────┘
```

The UI in podman talks to a local nginx that reverse-proxies `/api` to a
`aws ssm start-session` port-forward. **No ALB, no ACM cert, no public ingress.**
Set `enable_alb = true` in `terraform.tfvars` if you want the classic public
ALB instead.

## What's different from the base repo

| Area | Base repo | This repo |
|---|---|---|
| GPU support | CPU-only `t3.micro` | 6 partitions: T4, A10G, L4, A100, 1×H100, 8×H100 |
| Database | MariaDB on head node | **Aurora Serverless v2 MySQL** (single AZ) |
| Cache | None | **Valkey Serverless** (ElastiCache) |
| UI access | Public web | **Local podman + SSM port-forward** (ALB optional) |
| Workflow engine | None | **Workflow node** with Snakemake + Slurm executor |
| Upload limit | 500 MB via nginx | **Direct-to-S3 multipart**, 10 GB+ |
| Models | N/A | Catalog in Aurora with GPU-memory filtering |
| Users | Hardcoded user1/user2 | Team members table with roles, budgets, H100 approval |
| Container runtime | None | Docker + NVIDIA Container Toolkit + s5cmd on DLAMI |
| Cost controls | None | Per-user monthly budget enforced at submit |
| Capacity handling | Single AZ, fail-on-missing | Multi-AZ retry for H100 InsufficientInstanceCapacity |

## Components

- **Network** — VPC with public subnets (NAT + login node + optional ALB) and private subnets (head node, workflow node, Aurora, Valkey, compute). Default deployment AZ is **us-east-1f**.
- **Head node** — `slurmctld`, `slurmdbd`, nginx + FastAPI + React SPA in Docker Compose. Reachable via SSM Session Manager or the optional ALB.
- **Workflow node** — t3.small with Snakemake + Slurm executor plugin preinstalled. Submits DAG jobs into the cluster. Toggle with `enable_workflow_node`.
- **Login node** — t3.small in a public subnet for SSH access. Toggle with `enable_login_node`.
- **Aurora Serverless v2** — two databases: `slurm_acct_db` (slurmdbd) and `jobui` (app).
- **Valkey Serverless** — session tokens, rate limiting, queue status cache.
- **FSx Lustre SCRATCH_2** — `/fsx/models/<m>/` weights, `/fsx/work/<u>/<job>/` scratch, `/fsx/shared/` for workflows.
- **GPU compute fleet** — 6 launch templates (one per family), DLAMI base, autoscales 0→N via Slurm Resume/SuspendProgram with per-partition timing.
- **S3** — data bucket with per-user prefixes, versioned, encrypted, no public access.
- **ECR** — per-team repositories for model images.

## Submit flow (UI)

1. Browser (podman localhost:3000) → nginx → SSM tunnel → FastAPI on head node: `POST /api/uploads/init` returns presigned S3 multipart URLs
2. Browser uploads file directly to S3 in 8 MB chunks, in parallel (cancellable)
3. Browser: `POST /api/uploads/complete` — multipart merge, ETag stored as content_sha256
4. User picks GPU family + count + model + runtime → FastAPI validates budget, estimates cost, writes `jobs` row, shells out to `sbatch`
5. Slurm queues job; `ResumeProgram` picks launch template by GPU family and calls `ec2:RunInstances`. H100 retries across AZs on `InsufficientInstanceCapacity`.
6. Compute node boots from DLAMI, mounts FSx, registers with Slurm
7. Job script: `s5cmd cp` S3→FSx → `docker run --gpus all` with `--gres=gpu:<family>:<count>` → `s5cmd cp` results FSx→S3 → log archive → scratch cleanup
8. `slurmdbd` flushes accounting to Aurora; hourly cron rolls into `jobui.monthly_spend`
9. `SuspendProgram` terminates node after the per-partition `SuspendTime`

## Snakemake / workflow flow

```bash
aws ssm start-session --target $(terraform output -raw workflow_node_instance_id)
# On the workflow node:
cd /fsx/shared/snakemake-demo
snakemake --profile slurm --jobs 5
```

Each Snakemake rule with `resources: gpu=1` becomes a Slurm job. Local rules
run in-process on the workflow node. State is shared via FSx. See
[`examples/snakemake-demo/`](examples/snakemake-demo/) for a 3-rule fan-out
example (chunk → N parallel inferences → merge).

## Prerequisites

- Terraform ≥ 1.9
- AWS CLI v2 with the Session Manager plugin
- Podman + podman-compose (or Docker Desktop)
- **EC2 quota for the GPU families you plan to use** — request ahead of time:
  - `Running On-Demand G and VT instances` (T4/A10G/L4) — default often 0, request ≥ 4 vCPU for testing
  - `Running On-Demand P instances` (A100/H100) — default 0. Must request. Expect 1–2 weeks for H100 approval.
- (Only if `enable_alb = true`) An ACM certificate ARN in the same region

## Quick start ($100-budget cost-conscious deploy)

```bash
# 1. Customize tfvars
cp terraform.tfvars.example terraform.tfvars
# Edit ssh_allowed_cidr (your /32), admin_email, team_members
# Defaults already set: enable_alb=false, gpu_families_enabled=["t4","l4"]

# 2. Init Terraform (uses S3 backend; configure separately or use local state)
terraform init

# 3. Apply (~6 min; head node finishes Slurm build in another ~10 min after that)
terraform apply -var-file=terraform.tfvars

# 4. Capture outputs you'll use repeatedly
terraform output -raw ssm_port_forward_command > /tmp/ssm-fwd.sh
terraform output -raw admin_temp_password_command > /tmp/admin-pwd.sh
terraform output -raw workflow_node_ssm_command   > /tmp/workflow-ssm.sh

# 5. Upload the Snakemake demo to S3 so the workflow node can stage it
BUCKET=$(terraform output -raw s3_data_bucket)
aws s3 sync examples/snakemake-demo/ "s3://$BUCKET/platform/examples/snakemake-demo/"

# 6. Start the local UI
#    Terminal A — SSM tunnel (leave running):
bash /tmp/ssm-fwd.sh
#    Terminal B — podman UI:
cd local-ui && podman-compose up --build
# Open http://localhost:3000

# 7. Get the admin temp password
bash /tmp/admin-pwd.sh

# 8. Run tests (see TEST_PLAN.md)

# 9. Destroy
bash scripts/destroy.sh terraform.tfvars
```

## Cost model

**Always-on infrastructure (ALB off, default config)**

| Resource | Hourly | Daily |
|---|---|---|
| Head node `t3.medium` | $0.0416 | $1.00 |
| Login node `t3.small` (optional) | $0.0208 | $0.50 |
| Workflow node `t3.small` (optional) | $0.0208 | $0.50 |
| Aurora Serverless v2 (0.5 ACU min) | $0.06 | $1.44 |
| Valkey Serverless | ~$0.07 | $1.70 |
| FSx Lustre SCRATCH_2 (1.2 TiB min) | $0.14 | $3.36 |
| NAT Gateway | $0.045 | $1.08 |
| VPC interface endpoints ×8 | $0.08 | $1.92 |
| ALB (only if `enable_alb=true`) | $0.0225 | $0.54 |
| **Baseline (ALB off)** | **~$0.44/hr** | **~$10.50/day** |

Plus GPU-hour costs only while compute nodes run (autoscales to 0 when idle).

A full deploy → test → destroy cycle of 4 hours ≈ **$2–5** all-in.
See [TEST_PLAN.md](TEST_PLAN.md) for a $100-budget testing playbook covering
~15 full sessions of mixed CPU / GPU / Snakemake / failure-path scenarios.

## Repo layout

```
.
├── main.tf                          # root module — orchestrates everything
├── variables.tf                     # all input variables
├── outputs.tf                       # SSM commands, instance IDs, etc.
├── terraform.tfvars.example         # cost-optimized template (copy → terraform.tfvars)
├── modules/
│   ├── network/                     # VPC, subnets, NAT, VPC endpoints, SGs
│   ├── iam/                         # roles per node class (head/compute/login)
│   ├── s3/                          # data bucket + lifecycle + CORS
│   ├── ecr/                         # per-team model image repos
│   ├── aurora/                      # Serverless v2 MySQL
│   ├── valkey/                      # ElastiCache Serverless
│   ├── fsx/                         # Lustre SCRATCH_2
│   ├── alb/                         # optional public ALB
│   ├── head-node/                   # slurmctld + slurmdbd + jobui docker stack
│   ├── login-node/                  # optional SSH entry
│   ├── workflow-node/               # Snakemake / Nextflow runner
│   └── compute-fleet/               # GPU launch templates per family
├── jobui/
│   ├── backend/                     # FastAPI + SQLAlchemy + Alembic
│   └── frontend/                    # React + Vite SPA
├── local-ui/                        # podman-compose for laptop frontend
├── examples/
│   ├── evo2-inference-container/    # reference Docker model contract
│   └── snakemake-demo/              # 3-rule fan-out pipeline
├── jobs/                            # reference Slurm scripts (CLI use)
├── scripts/                         # destroy.sh, stage-model-weights.sh
├── docs/user-guide.md
├── TEST_PLAN.md                     # $100-budget test scenarios
└── README.md
```

## Documentation

- [TEST_PLAN.md](TEST_PLAN.md) — 9-scenario test playbook with cost estimates
- [local-ui/README.md](local-ui/README.md) — local podman UI setup + troubleshooting
- [examples/snakemake-demo/README.md](examples/snakemake-demo/README.md) — Snakemake fan-out pipeline
- [examples/evo2-inference-container/README.md](examples/evo2-inference-container/README.md) — model container contract
- [docs/user-guide.md](docs/user-guide.md) — end-user guide for the web UI

## License

MIT
