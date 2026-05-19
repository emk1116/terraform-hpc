# Titan HPC — GPU Inference Platform

Production-grade HPC cluster on AWS for **team-scale GPU inference and workflow
execution**. One team gets one cluster. Team members log into a web UI, upload
input files (up to 10 GB), pick a GPU type and a model, click submit. Slurm
spins up the matching GPU instance, pulls the model container from ECR, runs
inference against weights staged on FSx Lustre, uploads results back to S3,
and terminates the node when idle. A dedicated **workflow node** runs
Snakemake / Nextflow pipelines that fan out into the same Slurm cluster.

Enhanced fork of [`emk1116/terraform-hpc`](https://github.com/emk1116/terraform-hpc) — same Slurm-on-AWS pattern, significantly expanded for containerized GPU inference at team scale with H100-class workloads and DAG workflows.

## Topology

The platform separates **stateless web services** (jobui frontend + backend)
from **stateful HPC control plane** (Slurm controllers) and **compute**
(autoscaled GPU nodes). Web services run on Fargate so they can scale, deploy,
and restart independently of the Slurm controller. The head node is reduced
to its core job — running `slurmctld` + `slurmdbd` — and never serves web
traffic.

Two deployment modes share the same AWS backend. Use the **laptop-podman**
mode for development and end-to-end testing; use the **Fargate** mode for
team access.

### Production: jobui frontend + backend on Fargate (target topology)

```
                          ┌──────────────────────────────────────────────────┐
                          │  AWS VPC                                         │
    internet              │                                                  │
        │                 │   public subnets                                 │
        ▼                 │   ┌──────────┐                                   │
   https://ui.team        │   │   ALB    │                                   │
        │  (ACM cert)     │   │  :443    │                                   │
        └─────────────────┼──►│          │                                   │
                          │   └────┬─────┘                                   │
                          │        │                                         │
                          │   private subnets                                │
                          │        │                                         │
                          │   ┌────▼──────────────────────────────────────┐  │
                          │   │  Fargate task — jobui                     │  │
                          │   │   nginx :80  ─→  serves SPA               │  │
                          │   │     │                                     │  │
                          │   │     └─/api/*─→  FastAPI :8000             │  │
                          │   │                  • sbatch / squeue / sacct│  │
                          │   │                    (munge + slurm.conf,   │  │
                          │   │                     →  head node :6817)   │  │
                          │   │                  • Aurora :3306           │  │
                          │   │                  • Valkey :6379           │  │
                          │   │                  • S3 (uploads, logs)     │  │
                          │   └───────────────┬───────────────────────────┘  │
                          │                   │ port 6817 (slurmctld)        │
                          │   ┌───────────────▼───────────────────────────┐  │
                          │   │  head node — slurmctld + slurmdbd only    │  │
                          │   │     no web server, no Docker compose      │  │
                          │   └─────────┬─────────────────────────────────┘  │
                          │             │                                    │
                          │   ┌─────────▼─────────┬──────────────────────┐   │
                          │   │ workflow node     │ compute fleet        │   │
                          │   │  Snakemake →      │  T4/L4/A10G/         │   │
                          │   │  sbatch           │  A100/H100           │   │
                          │   └───────────────────┴──────────────────────┘   │
                          │                                                  │
                          │   shared services                                │
                          │   ┌────────────┬───────────┬─────────────────┐   │
                          │   │ Aurora v2  │ Valkey    │ FSx Lustre /fsx │   │
                          │   └────────────┴───────────┴─────────────────┘   │
                          └──────────────────────────────────────────────────┘
```

- **ALB** terminates TLS; the only public-facing component. Requires an ACM
  cert in the same region.
- **Fargate task** runs **two containers** in one task definition:
  - `nginx` — serves the React SPA build, reverse-proxies `/api/*` to
    `localhost:8000` inside the same task
  - `jobui-backend` — FastAPI + Slurm CLI + munge daemon. Submits jobs into
    the cluster via `sbatch` over TCP :6817 to the head node, authenticated
    with the same munge key the cluster uses (fetched from SSM at task start).
- **Head node** is **simplified** in this mode: it only runs `slurmctld` and
  `slurmdbd` and uploads `slurm.conf` + the Slurm client tarball to S3 so
  the Fargate task can fetch them at startup. No more nginx, no jobui stack,
  no Docker Compose on the head node.
- **FSx access**: Fargate **cannot mount FSx Lustre** (AWS limitation). The
  backend reads live logs by tailing `/fsx/work/<u>/<j>/slurm.log` *only*
  when running in laptop-test mode (which mounts FSx via the head node).
  In Fargate mode, the backend reads logs from the S3 archive that the job
  script writes when it exits — this means **live logs are only available
  after job completion**. See [Roadmap](#roadmap--known-gaps) for the
  EFS-backed log fanout option.

Set `enable_alb = true` and `enable_jobui_fargate = true` in
`terraform.tfvars` to opt in once the module ships.

> Status: the Fargate module for jobui (frontend + backend together) is a
> planned addition. Until then, the laptop-podman path below carries the
> backend itself, and TEST_PLAN.md assumes that mode. Track progress in
> [Roadmap](#roadmap--known-gaps) below.

### Testing / development: laptop podman runs frontend + backend

```
┌─────────────────────────┐  3× aws ssm  ┌─────────────────────────────────┐
│  Your laptop            │  port-fwds   │  AWS VPC (private)              │
│                         │ ───────────► │                                 │
│ podman frontend :3000   │              │  head node                      │
│   └─ /api/* ──────────┐ │              │   slurmctld + slurmdbd          │
│                       │ │              │     :6817 ◄──── (sbatch tunnel) │
│ podman backend :8000  ◄┘ │              │                                 │
│   ├─ sbatch ──────────────────────────►│   workflow node ─ sbatch        │
│   ├─ Aurora :3306 ────────────────────►│   Aurora :3306                  │
│   └─ Valkey :6379 ────────────────────►│   Valkey :6379                  │
│                         │              │   FSx Lustre (head node only)   │
└─────────────────────────┘              │   compute fleet (autoscaled)    │
                                         └─────────────────────────────────┘
```

Local podman runs **both** the frontend and backend containers — the same
images that ship to Fargate in production. The backend opens three SSM
port-forwards to reach Slurm (`:6817`), Aurora (`:3306`), and Valkey (`:6379`)
inside the VPC. **No ALB, no ACM cert, no public ingress.** This is the
default config in `terraform.tfvars.example` and the topology used in
[TEST_PLAN.md](TEST_PLAN.md).

> Live FSx log tailing is available in this mode only if you also forward
> the head node's log directory via SSM (the head node still mounts FSx in
> both modes). Otherwise, completed-job logs are read from the S3 archive.

## What's different from the base repo

| Area | Base repo | This repo |
|---|---|---|
| GPU support | CPU-only `t3.micro` | 6 partitions: T4, A10G, L4, A100, 1×H100, 8×H100 |
| Database | MariaDB on head node | **Aurora Serverless v2 MySQL** (single AZ) |
| Cache | None | **Valkey Serverless** (ElastiCache) |
| UI + backend hosting | Both on head node | **Fargate task** (nginx + FastAPI) for prod; **local podman** for testing. Head node runs only Slurm. |
| Workflow engine | None | **Workflow node** with Snakemake + Slurm executor |
| Upload limit | 500 MB via nginx | **Direct-to-S3 multipart**, 10 GB+ |
| Models | N/A | Catalog in Aurora with GPU-memory filtering |
| Users | Hardcoded user1/user2 | Team members table with roles, budgets, H100 approval |
| Container runtime | None | Docker + NVIDIA Container Toolkit + s5cmd on DLAMI |
| Cost controls | None | Per-user monthly budget enforced at submit |
| Capacity handling | Single AZ, fail-on-missing | Multi-AZ retry for H100 InsufficientInstanceCapacity |

## Components

- **Network** — VPC with public subnets (NAT + ALB + Fargate ENIs + login node) and private subnets (head node, workflow node, Aurora, Valkey, compute, Fargate). Default deployment AZ is **us-east-1f**.
- **ALB** *(optional)* — public-facing, TLS-terminating. Forwards everything to the jobui Fargate task. Required for the Fargate deployment mode.
- **jobui Fargate service** *(planned)* — single ECS task definition with two containers:
  - `nginx` — serves the SPA build, reverse-proxies `/api/*` to `localhost:8000`
  - `jobui-backend` — FastAPI + Slurm CLI + munge daemon; submits to head node `slurmctld` over TCP. Fetches `slurm.conf` and Slurm binaries from S3 (uploaded by head node at boot) and the munge key from SSM Parameter Store.
- **Head node** — `slurmctld` + `slurmdbd` **only** in Fargate mode. No more web server, no jobui Docker stack. Still uploads platform artifacts (slurm.conf, slurm-client tarball, resume/suspend scripts) to S3 so Fargate tasks, workflow nodes, and compute nodes can fetch them.
- **Workflow node** — t3.small with Snakemake + Slurm executor plugin preinstalled. Submits DAG jobs into the cluster. Toggle with `enable_workflow_node`.
- **Login node** — t3.small in a public subnet for SSH access. Toggle with `enable_login_node`.
- **Aurora Serverless v2** — two databases: `slurm_acct_db` (slurmdbd) and `jobui` (app).
- **Valkey Serverless** — session tokens, rate limiting, queue status cache.
- **FSx Lustre SCRATCH_2** — `/fsx/models/<m>/` weights, `/fsx/work/<u>/<job>/` scratch, `/fsx/shared/` for workflows. Mounted by head, workflow, and compute nodes. **Not mounted by Fargate** — see Roadmap for the EFS-or-sidecar plan to expose live FSx logs to the Fargate backend.
- **GPU compute fleet** — 6 launch templates (one per family), DLAMI base, autoscales 0→N via Slurm Resume/SuspendProgram with per-partition timing.
- **S3** — data bucket with per-user prefixes, versioned, encrypted, no public access. Also hosts the slurm.conf + slurm-client tarball that Fargate tasks pull at startup, and the completed-job log archives.
- **ECR** — per-team repositories for model images, plus `jobui/frontend` and `jobui/backend` images when Fargate mode is enabled.

## Submit flow (UI)

1. Browser → ALB → Fargate `nginx` → Fargate `jobui-backend` (same task, `localhost:8000`). In testing mode: Browser → podman nginx → podman backend on the laptop.
2. `POST /api/uploads/init` returns presigned S3 multipart URLs; browser uploads file directly to S3 in 8 MB chunks (cancellable).
3. `POST /api/uploads/complete` — multipart merge, ETag stored as `content_sha256`.
4. User picks GPU family + count + model + runtime. FastAPI validates budget against Aurora, estimates cost, writes `jobs` row, then **shells out to `sbatch`**. The Fargate backend has a local munge daemon (same key as the cluster) and an embedded `slurm.conf` pointing at the head node's `slurmctld`. The sbatch traffic is plain Slurm RPC over TCP :6817, authenticated with munge.
5. Slurm queues the job; `ResumeProgram` picks the launch template by GPU family and calls `ec2:RunInstances`. H100 retries across AZs on `InsufficientInstanceCapacity`.
6. Compute node boots from DLAMI, mounts FSx, registers with Slurm.
7. Job script: `s5cmd cp` S3→FSx → `docker run --gpus all` with `--gres=gpu:<family>:<count>` → `s5cmd cp` results FSx→S3 → log archive to `s3://.../logs/<u>/<job>/slurm.log` → scratch cleanup.
8. `slurmdbd` flushes accounting to Aurora; hourly cron rolls into `jobui.monthly_spend`.
9. `SuspendProgram` terminates the node after the per-partition `SuspendTime`.
10. When the user opens the job detail page, the Fargate backend reads `log_tail` from the S3 archive (the FSx scratch dir is already cleaned up by then). For *running* jobs the live log is only available in laptop-test mode.

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
- Podman + podman-compose (or Docker Desktop) — only for the laptop testing path
- **EC2 quota for the GPU families you plan to use** — request ahead of time:
  - `Running On-Demand G and VT instances` (T4/A10G/L4) — default often 0, request ≥ 4 vCPU for testing
  - `Running On-Demand P instances` (A100/H100) — default 0. Must request. Expect 1–2 weeks for H100 approval.
- An ACM certificate ARN in the same region — required when `enable_alb = true` (Fargate mode)

## Quick start ($100-budget cost-conscious deploy — laptop testing path)

This path validates the full backend, FSx, Slurm, autoscale, and Snakemake
behavior end-to-end without paying for the ALB or Fargate. Use it to iterate
on the stack before turning on the production UI.

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

## Production deployment (jobui on Fargate)

Once the laptop-podman path is validated and you're ready to expose the UI
to teammates, flip these toggles in `terraform.tfvars`:

```hcl
enable_alb            = true
enable_jobui_fargate  = true                # planned; see Roadmap
acm_certificate_arn   = "arn:aws:acm:us-east-1:...:certificate/..."
cors_allowed_origins  = "https://your-team-ui.example.com"
```

What changes:
- A public **ALB** terminates HTTPS at your hostname
- A **Fargate task** runs two containers in one task definition:
  - `nginx` (from `jobui/frontend/Dockerfile`) — SPA + `/api/*` reverse-proxy
  - `jobui-backend` (from `jobui/backend/Dockerfile`) — FastAPI + Slurm CLI + munge
- The Fargate task fetches `slurm.conf` and the Slurm client binaries from S3
  on startup (uploaded by the head node) and the munge key from SSM Parameter
  Store. Its security group allows egress to head node `:6817` and to Aurora/Valkey.
- **The head node loses its web stack** — no more nginx, no jobui Docker
  compose. Just `slurmctld` + `slurmdbd`. The bootstrap script gets ~200
  lines lighter.
- Users open `https://your-team-ui.example.com` — no SSM, no podman, no SSH.
- The head node still has no public ingress.

Add-on cost over the laptop-test baseline: ~$1.20/day (ALB ~$0.54 + 1 small
Fargate task at 0.5 vCPU / 1 GB ~$0.65). The laptop path remains useful for
debugging and CI integration tests.

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
| Fargate jobui task 0.5 vCPU / 1 GB (only if `enable_jobui_fargate=true`) | $0.0271 | $0.65 |
| **Baseline (laptop-test mode — ALB+Fargate off)** | **~$0.44/hr** | **~$10.50/day** |
| **Baseline (production mode — ALB + Fargate on)** | **~$0.49/hr** | **~$11.70/day** |

In production mode, the head node typically drops to `t3.small` (no jobui
stack to run); the slurmctld + slurmdbd workload is light. That saves another
~$0.50/day, mostly offsetting the Fargate task cost.

Plus GPU-hour costs only while compute nodes run (autoscales to 0 when idle).

A full laptop-test deploy → test → destroy cycle of 4 hours ≈ **$2–5** all-in.
See [TEST_PLAN.md](TEST_PLAN.md) for a $100-budget playbook covering ~15 full
sessions of mixed CPU / GPU / Snakemake / failure-path scenarios.

## Roadmap / known gaps

| Item | State | Notes |
|---|---|---|
| `modules/jobui-fargate/` | **Not yet written** | ECS cluster + task definition with two containers (`nginx` for SPA + `jobui-backend` for FastAPI) + service + target group on the ALB. Requires both `jobui/frontend` and `jobui/backend` images to be pushed to ECR. Backend container needs `slurm-client`, `munge`, and AWS CLI installed. |
| Head-node simplification when Fargate is on | **Not yet written** | When `enable_jobui_fargate = true`, the head-node user_data should skip steps 2 (slurm build is fine), 4–6 (still needed for slurmctld/slurmdbd), but drop 8–11 (no jobui docker compose, no nginx). Head node instance can also downsize to t3.small. |
| Slurm RPC ingress on head node | **Needs SG change** | Currently `head_node_sg` only allows `6817-6819` from inside the VPC. The Fargate task ENI lands in the VPC private subnets so this already works, but the SG rule should be tightened to allow `6817` specifically from the Fargate SG. |
| FSx live-log access from Fargate | **Open** | Fargate cannot mount FSx Lustre. Options: (a) sidecar HTTP server on head node serving `/fsx/work/**/slurm.log` to the backend SG only; (b) EFS volume mounted on both compute nodes and Fargate, with logs tee'd to EFS; (c) accept S3-only logs (live = unavailable, completed = OK). |
| Munge key distribution to Fargate | **Pattern exists** | Workflow + compute nodes already fetch the key from SSM Parameter Store at startup. The Fargate task definition just needs the same IAM permission and an entrypoint that fetches the key and starts `munged` before the FastAPI process. |
| Slurm MIG GRES integration | Not wired | H100/A100 MIG slices can be configured manually on the compute node (see [TEST_PLAN.md](TEST_PLAN.md) §Scenario 6). Full automation would add a `gres.conf` template per-MIG-profile and a new `gpu_family_spec` entry. |
| CPU compute partition | Not wired | All test jobs currently run on T4/L4 nodes with `--gres=gpu:t4:0` as a workaround. A real CPU partition would need a non-DLAMI launch template branch in `modules/compute-fleet`. |
| Frontend dead code | Cosmetic | `pages/SubmitJob.jsx`, `pages/Dashboard.jsx`, `api/*.js`, `hooks/*.js`, `components/*.jsx` are leftovers; safe to delete. |
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
│   ├── iam/                         # roles per node class (head/compute/login)
│   ├── s3/                          # data bucket + lifecycle + CORS
│   ├── ecr/                         # per-team model + frontend image repos
│   ├── aurora/                      # Serverless v2 MySQL
│   ├── valkey/                      # ElastiCache Serverless
│   ├── fsx/                         # Lustre SCRATCH_2
│   ├── alb/                         # optional public ALB (for Fargate jobui)
│   ├── head-node/                   # slurmctld + slurmdbd (in Fargate mode: nothing else)
│   ├── login-node/                  # optional SSH entry
│   ├── workflow-node/               # Snakemake / Nextflow runner
│   ├── compute-fleet/               # GPU launch templates per family
│   └── (jobui-fargate/)             # planned — ECS Fargate task: nginx + jobui-backend
├── jobui/
│   ├── backend/                     # FastAPI + SQLAlchemy + Alembic (deploys to Fargate)
│   └── frontend/                    # React + Vite SPA (deploys to Fargate as nginx sidecar)
├── local-ui/                        # podman-compose: both frontend + backend on laptop
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
