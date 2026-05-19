# Titan HPC — GPU Inference Platform

Production-grade HPC cluster on AWS for **team-scale GPU inference and workflow
execution**. Pure Slurm + FSx + autoscaled GPUs. Users `aws ssm start-session`
into the **login node** and submit jobs with `sbatch` or `snakemake`. The
cluster has **no user-facing web service**: it's HPC
infrastructure, not a SaaS.

A web UI for users who prefer point-and-click access lives in [`jobui/`](jobui/);
it's a **separate concern** scheduled to ship as a Fargate service in a later
phase, with the HPC cluster as its backend. For now, assume the Fargate jobui
exists "somewhere else" — this repo only owns the HPC side and never depends
on the UI being deployed.

Enhanced fork of [`emk1116/terraform-hpc`](https://github.com/emk1116/terraform-hpc) — same Slurm-on-AWS pattern, expanded for containerized GPU inference at team scale with H100-class workloads and DAG workflows.

## Topology

```
                  ┌─────────────────────────────────────────────────────────────┐
                  │  AWS VPC                                                    │
   operator       │                                                             │
       │          │  ┌──────────────────────────┐   ┌──────────────────────┐    │
       │  aws ssm │  │  LOGIN NODE              │   │  WORKFLOW NODE       │    │
       ├──────────┼─►│  (interactive entry)     │   │  (long-running DAGs) │    │
       │          │  │  • SSM + SSH (EIP)       │   │  • SSM only          │    │
       │          │  │  • sbatch / squeue /sacct│   │  • Snakemake daemon  │    │
       │  aws ssm │  │  • Snakemake preinstalled│   │  • Slurm client      │    │
       └──────────┼─►│  • munge + slurm.conf    │   │  • munge + slurm.conf│    │
                  │  │  • FSx /fsx mounted      │   │  • FSx /fsx mounted  │    │
                  │  └────────────┬─────────────┘   └─────────┬────────────┘    │
                  │               │                           │                 │
                  │               │  sbatch over :6817 (munge-authenticated)    │
                  │               │                           │                 │
                  │               └────────────┬──────────────┘                 │
                  │                            ▼                                │
                  │                ┌────────────────────────────────────┐       │
                  │                │  HEAD NODE  (control plane only)   │       │
                  │                │  • slurmctld                       │       │
                  │                │  • slurmdbd ──► Aurora             │       │
                  │                │  • ResumeProgram / SuspendProgram  │       │
                  │                └─────────────────┬──────────────────┘       │
                  │                                  │ ec2:RunInstances         │
                  │                                  ▼                          │
                  │                ┌────────────────────────────────────┐       │
                  │                │  COMPUTE FLEET (autoscaled 0→N)    │       │
                  │                │   T4 / L4 / A10G / A100 / H100     │       │
                  │                └────────────────────────────────────┘       │
                  │                                                             │
                  │  shared services (mounted / connected by all nodes above)   │
                  │  ┌─────────────────────┬───────────────────────────────┐    │
                  │  │ Aurora v2           │ FSx Lustre /fsx               │    │
                  │  │ (slurmdbd acct DB)  │ (models, scratch, /shared)    │    │
                  │  └─────────────────────┴───────────────────────────────┘    │
                  │                                                             │
                  │  S3 (uploads, results, slurm.conf, slurm-client tarball,    │
                  │      completed-job log archives)                            │
                  │  ECR (model container images)                               │
                  └─────────────────────────────────────────────────────────────┘

                  (separate concern, future phase)
                  ┌──────────────────────────────────────────────────────┐
                  │  Fargate jobui — deployed separately, submits jobs   │
                  │  by talking to the login node (same way users do)    │
                  └──────────────────────────────────────────────────────┘
```

### Two ways to use the cluster

| Path | Who it's for | How |
|---|---|---|
| **CLI** (primary, always available) | All users, scripts, CI | `aws ssm start-session --target <login-node>`, then `sbatch` or `snakemake`. No UI required. |
| **Web UI** (future, separate deployment) | Researchers who prefer point-and-click | Fargate-deployed jobui (out of scope here) talks to the login node. The UI deployment is **not built by this repo's `terraform apply`** in the new design. |

The HPC cluster works identically whether or not the UI is deployed. There is
no fallback path inside the HPC stack that requires a UI; everything is
`sbatch` underneath.

## What's different from the base repo

| Area | Base repo | This repo |
|---|---|---|
| GPU support | CPU-only `t3.micro` | 6 partitions: T4, A10G, L4, A100, 1×H100, 8×H100 |
| Accounting DB | MariaDB on head node | **Aurora Serverless v2 MySQL** (single AZ, holds `slurm_acct_db`) |
| Cache | None | **Valkey Serverless** (used by optional jobui only) |
| User-facing surface | Head node directly | **Login node only** — head node is invisible control plane |
| Workflow engine | None | **Login or workflow node** runs Snakemake + Slurm executor |
| Container runtime | None | Docker + NVIDIA Container Toolkit + s5cmd on DLAMI |
| Cost controls | None | Per-user monthly budget enforced in Slurm accounting (TRES caps + sacctmgr) |
| Capacity handling | Single AZ, fail-on-missing | Multi-AZ retry for H100 InsufficientInstanceCapacity |
| Users | Hardcoded user1/user2 | Slurm accounts seeded from `team_members` tfvars |

## Components

- **Network** — VPC with public subnets (NAT + login node) and private subnets (head node, workflow node, Aurora, Valkey, compute, FSx). Default deployment AZ is **us-east-1f**.
- **Login node** — User's entry point. AL2023 in a public subnet, EIP attached. SSM Session Manager + SSH. FSx mounted at `/fsx`. **Slurm client + Snakemake preinstalled** so users can run `sbatch` or `snakemake --profile slurm` directly. The future Fargate UI also submits through this node. (Nextflow / Cromwell can be added later if the team needs them.)
- **Head node** — Slurm control plane only. Runs `slurmctld` + `slurmdbd`. **No web server, no UI.** Reachable only via SSM by admins. Uploads `slurm.conf` and Slurm client binaries to S3 so other nodes can fetch them.
- **Workflow node** — t3.small with the same Snakemake + Slurm executor plugin preinstalled. Required component; provides isolated process space for long-running DAG daemons so they don't fight interactive use on the login node. Both nodes can submit DAGs — pick the workflow node for production runs and the login node for quick interactive iteration.
- **Aurora Serverless v2** — holds `slurm_acct_db` (slurmdbd accounting). When the future Fargate UI lands it also gets a `jobui` database; that's not in scope for this repo.
- **Valkey Serverless** — provisioned in the VPC for the future UI. Not used by the HPC cluster itself.
- **FSx Lustre SCRATCH_2** — `/fsx/models/<m>/` weights, `/fsx/work/<u>/<job>/` scratch, `/fsx/shared/` for workflows.
- **GPU compute fleet** — 6 launch templates (one per family), DLAMI base, autoscales 0→N via Slurm Resume/SuspendProgram with per-partition timing.
- **S3** — data bucket: per-user prefixes for inputs/results, hosts the slurm.conf + slurm-client tarball, plus the completed-job log archives written by job epilogs.
- **ECR** — per-team repositories for model images.

## Workflow

### Direct CLI use (the primary path)

```bash
# 1. Enter the login node
aws ssm start-session --target $(terraform output -raw login_node_instance_id)

# 2. (Inside the login node) submit a job — any sbatch script you like
sbatch jobs/inference_job.sh

# 3. Check status
squeue -u $USER
sacct -X --format=JobID,Partition,State,Elapsed,ReqTRES -S today

# 4. Results land in S3
aws s3 ls "s3://$(terraform output -raw s3_data_bucket)/results/"
```

### Snakemake

```bash
# On the login node (or workflow node):
cd /fsx/shared/snakemake-demo
snakemake --profile slurm --jobs 5
```

Each rule with `resources: gpu=1` becomes a Slurm job. Local rules run on the
host. State is shared via FSx. See [`examples/snakemake-demo/`](examples/snakemake-demo/)
for a 3-rule fan-out example.

### Web UI

Out of scope for this repo. When the Fargate-deployed jobui is wired in
later, it will hit the login node over a yet-to-be-defined surface (likely
either an HTTPS API exposed by a small daemon on the login node, or SSH-based
sbatch via an IAM-authenticated AWS Systems Manager session). Until then,
ignore the [`jobui/`](jobui/) directory — it's there as reference code for
that future phase.

## Prerequisites

- Terraform ≥ 1.9
- AWS CLI v2 with the Session Manager plugin
- **EC2 quota for the GPU families you plan to use** — request ahead of time:
  - `Running On-Demand G and VT instances` (T4/A10G/L4) — default often 0, request ≥ 4 vCPU for testing
  - `Running On-Demand P instances` (A100/H100) — default 0. Must request. Expect 1–2 weeks for H100 approval.

## Quick start ($100-budget cost-conscious deploy)

```bash
# 1. Customize tfvars
cp terraform.tfvars.example terraform.tfvars
# Edit ssh_allowed_cidr (your /32), admin_email, team_members

# 2. Init Terraform (S3 backend; configure separately or use local state)
terraform init

# 3. Apply (~6 min; head node finishes Slurm build in another ~10 min after that)
terraform apply -var-file=terraform.tfvars

# 4. Enter the login node and start running jobs
LOGIN_ID=$(terraform output -raw login_node_instance_id)
aws ssm start-session --target $LOGIN_ID

# On the login node:
sinfo                                       # see partitions
sbatch jobs/inference_job.sh                # submit a job
squeue -u $USER                             # watch it
sacct -X -S today                           # accounting

# 5. Upload the Snakemake demo to S3 so login/workflow nodes can stage it
BUCKET=$(terraform output -raw s3_data_bucket)
aws s3 sync examples/snakemake-demo/ "s3://$BUCKET/platform/examples/snakemake-demo/"

# 6. Tests (see TEST_PLAN.md)

# 7. Destroy
bash scripts/destroy.sh terraform.tfvars
```

## Cost model

**Always-on infrastructure (pure HPC, no UI)**

| Resource | Hourly | Daily |
|---|---|---|
| Head node `t3.small` (slurmctld + slurmdbd) | $0.0208 | $0.50 |
| Login node `t3.small` (Slurm CLI + FSx mount) | $0.0208 | $0.50 |
| Workflow node `t3.small` | $0.0208 | $0.50 |
| Aurora Serverless v2 (0.5 ACU min) | $0.06 | $1.44 |
| Valkey Serverless (provisioned for future UI) | ~$0.07 | $1.70 |
| FSx Lustre SCRATCH_2 (1.2 TiB min) | $0.14 | $3.36 |
| NAT Gateway | $0.045 | $1.08 |
| VPC interface endpoints ×8 | $0.08 | $1.92 |
| **Baseline** | **~$0.43/hr** | **~$10.30/day** |

Plus GPU-hour costs only while compute nodes run (autoscales to 0 when idle).

A full deploy → test → destroy cycle of 4 hours ≈ **$2–5** all-in.
See [TEST_PLAN.md](TEST_PLAN.md) for a $100-budget playbook covering ~15 full
sessions of mixed GPU / Snakemake / failure-path scenarios.

You can shave another ~$1.70/day by setting `enable_valkey = false` in tfvars
if you have no plans to deploy the future jobui — Valkey only matters once
the UI is up. (Variable doesn't exist yet; see Roadmap.)

## Roadmap / known gaps

| Item | State | Notes |
|---|---|---|
| Remove jobui Docker stack from `head-user-data.sh.tpl` | **Code change pending** | Today the head node user_data still builds and runs the jobui Docker compose stack (~200 lines). Per the new design, HPC is pure HPC — those steps should be deleted. The `jobui/` directory stays in the repo as reference for the future Fargate deployment. |
| Add Slurm client install to login-node user_data | **Code change pending** | Current `login-node/user-data.sh.tpl` only mounts FSx and adds `/etc/hosts`. It needs to install munge, fetch `slurm-client-gpu.tar.gz` from S3, and place `slurm.conf` — same pattern `workflow-node/main.tf` already implements. |
| Move ALB module out of root `main.tf` | **Code change pending** | With no UI in the HPC stack, the ALB module shouldn't be conditionally instantiated here. It'll move to whatever repo owns the Fargate jobui. |
| `enable_valkey` toggle | **Not yet added** | If the team is HPC-only and won't deploy the future UI, Valkey is dead weight at ~$1.70/day. Add a boolean to skip it. |
| Drop `cors_allowed_origins`, `enable_alb`, `head_node_http_cidrs` from `variables.tf` | **Cleanup pending** | These are vestigial from the UI-on-head-node and UI-on-Fargate iterations. None applies to a pure-HPC stack. |
| Future: Fargate jobui module | **Out of scope** | Lives in a separate repo / future phase. Talks to this HPC cluster over a yet-to-be-designed contract. |
| Slurm MIG GRES integration | Not wired | H100/A100 MIG slices can be configured manually on the compute node (see [TEST_PLAN.md](TEST_PLAN.md) §Scenario 6). |
| CPU compute partition | Not wired | All test jobs currently run on T4/L4 nodes with `--gres=gpu:t4:0` as a workaround. |
| GPU / queue telemetry | Not deployed | No Prometheus/DCGM/Slurm exporter yet. Use `sinfo`, `squeue`, `nvidia-smi` over SSM. |

## Repo layout

```
.
├── main.tf                          # root module — orchestrates everything
├── variables.tf                     # all input variables
├── outputs.tf                       # SSM commands, instance IDs, etc.
├── terraform.tfvars.example         # cost-optimized template (copy → terraform.tfvars)
├── modules/
│   ├── network/                     # VPC, subnets, NAT, VPC endpoints, SGs
│   ├── iam/                         # roles per node class
│   ├── s3/                          # data bucket + lifecycle + CORS
│   ├── ecr/                         # per-team model image repos
│   ├── aurora/                      # Serverless v2 MySQL (slurm_acct_db)
│   ├── valkey/                      # ElastiCache Serverless (for future UI)
│   ├── fsx/                         # Lustre SCRATCH_2
│   ├── alb/                         # vestigial — to be moved out with the UI work
│   ├── head-node/                   # slurmctld + slurmdbd (control plane)
│   ├── login-node/                  # SSH/SSM entry + Slurm client + FSx
│   ├── workflow-node/               # Snakemake runner (required)
│   └── compute-fleet/               # GPU launch templates per family
├── jobui/                           # FUTURE — Fargate-deployed UI (not in HPC stack)
│   ├── backend/                     # FastAPI + SQLAlchemy + Alembic
│   └── frontend/                    # React + Vite SPA
├── local-ui/                        # local podman dev env for the future UI
├── examples/
│   ├── evo2-inference-container/    # reference Docker model contract
│   └── snakemake-demo/              # 3-rule fan-out pipeline
├── jobs/                            # reference Slurm scripts for CLI users
├── scripts/                         # destroy.sh, stage-model-weights.sh
├── docs/user-guide.md
├── TEST_PLAN.md                     # $100-budget test scenarios
└── README.md
```

## Documentation

- [TEST_PLAN.md](TEST_PLAN.md) — 9-scenario test playbook with cost estimates
- [examples/snakemake-demo/README.md](examples/snakemake-demo/README.md) — Snakemake fan-out pipeline
- [examples/evo2-inference-container/README.md](examples/evo2-inference-container/README.md) — model container contract
- [docs/user-guide.md](docs/user-guide.md) — end-user guide (legacy, covers the previous UI design)
- [local-ui/README.md](local-ui/README.md) — local UI dev environment (for the future Fargate jobui)

## License

MIT
