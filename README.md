# Titan HPC Cluster

Production-style HPC cluster on AWS using Slurm with autoscaling compute nodes, shared FSx for Lustre storage, an S3-backed data pipeline, and a browser-based web platform — deployed entirely via Terraform.

## Architecture

```
  User Browser          Login Node (SSH)         Head Node (t3.micro)
  ────────────          ────────────────         ────────────────────
  http://<ip>  ──────►  SSH entry point          Nginx :80
                         job submission            ├─ /api/* ──► FastAPI :8000
                         squeue / sacct            │              ├─ JWT auth
                                                   │              ├─ SQLite
                                                   │              ├─ boto3 → S3
                                                   │              └─ sbatch/sacct
                                                   └─ /     ──► React SPA
                                  │ Slurm RPC      │
                                  │ ec2:RunInstances│
                        ┌─────────▼──────────────────────────────────┐
                        │                  AWS VPC                    │
                        │                                             │
                        │  ┌──────────────────┐                       │
                        │  │    Head Node     │                       │
                        │  │    (t3.micro)    │                       │
                        │  │  • slurmctld     │                       │
                        │  │  • slurmdbd      │                       │
                        │  │  • MariaDB       │                       │
                        │  │  • jobui stack   │                       │
                        │  └────────┬─────────┘                       │
                        │           │ ec2:RunInstances                │
                        │  ┌────────▼──────────────────┐              │
                        │  │     Compute Nodes         │              │
                        │  │  (t3.micro × 0–N)         │◄─── S3 input │
                        │  │  Launched on job submit   │────► S3 results
                        │  │  Terminated after idle    │              │
                        │  └───────────┬───────────────┘              │
                        │              │ mount /fsx                   │
                        │  ┌───────────▼───────────────┐              │
                        │  │   FSx for Lustre (1.2TB)  │              │
                        │  │  /fsx/home/<user>  (755)  │              │
                        │  │  /fsx/work/<user>  (700)  │              │
                        │  │  /fsx/shared       (777)  │              │
                        │  └───────────────────────────┘              │
                        └─────────────────────────────────────────────┘
                                          │
                              ┌───────────▼───────────┐
                              │   S3 Data Bucket      │
                              │  input/{user_id}/     │◄── uploads (UI or CLI)
                              │  results/{job_id}/    │──► job output
                              │  • AES256 encrypted   │
                              │  • Versioning on      │
                              │  • No public access   │
                              └───────────────────────┘
```

**Autoscaling**: Slurm's `ResumeProgram` launches EC2 instances when jobs are queued. `SuspendProgram` terminates them after 120 seconds idle. No compute instances run when the cluster is idle.

**Login node enforcement**: Four independent layers prevent heavy jobs from running on the login node — PAM limits, cgroups, process watchdog, and shell policy overrides.

**S3 pipeline**: Jobs download input from S3 to FSx, process locally, upload results back to S3 under `results/<job_id>/`, then clean up FSx. No data persists on FSx between jobs.

**Web platform**: A FastAPI + React UI runs on the head node. Users submit jobs, upload files, and download results from a browser — no SSH required.

---

## Terraform Modules

| Module | Purpose |
|---|---|
| `network` | VPC, subnet, IGW, route table, login SG + HPC SG |
| `iam` | IAM roles and instance profiles (head, compute, login) — includes S3 scoped access |
| `head-node` | Head node EC2, EIP, Slurm controller + accounting |
| `login-node` | Login node EC2, EIP, job submission enforcement |
| `compute-fleet` | Launch template and ASG for compute nodes |
| `fsx` | FSx for Lustre SCRATCH_1 shared filesystem |
| `s3` | S3 data bucket with encryption, versioning, and public access block |

---

## Prerequisites

- Terraform >= 1.14.7
- AWS CLI configured (`aws configure`)
- An SSH key pair

---

## Quick Start

**1. Generate SSH key**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/titan-hpc -C "titan-hpc"
```

**2. Create your vars file**
```bash
cp non-prod.tfvars.example non-prod.tfvars
# Edit non-prod.tfvars — set ssh_allowed_cidr to your IP:
#   curl ifconfig.me
```

**3. Deploy**
```bash
terraform init
terraform apply -var-file=non-prod.tfvars
```
> FSx takes ~13 minutes to become available. Full cluster init takes ~15 minutes total.

**4. Connect via SSH (optional — CLI path)**
```bash
ssh -i ~/.ssh/titan-hpc ec2-user@<login_node_public_ip>
```

**5. Or open the web UI (no SSH needed)**
```bash
# On the head node — one-time setup
cd jobui
./setup.sh   # installs Docker, prompts for S3 bucket + JWT secret, starts stack
```
Access at `http://<head_node_public_ip>/`

**6. Run the S3 pipeline via CLI**
```bash
# Upload input data from your machine
aws s3 cp mydata.txt s3://<bucket>/input/

# From the login node — submit pipeline job as user1
sudo -u user1 sbatch /fsx/home/user1/s3_pipeline_job.sh

# Monitor
squeue
sinfo

# Verify results in S3
aws s3 ls s3://<bucket>/results/<job_id>/
aws s3 cp s3://<bucket>/results/<job_id>/summary.txt -
```

**7. Destroy everything**
```bash
bash destroy.sh
```
> Compute nodes, FSx, and S3 bucket (including all data) are fully destroyed. No charges remain.

---

## Web Platform (jobui/)

A browser-based UI for submitting and monitoring jobs without SSH access. Runs on the head node via Docker Compose.

### Features

- JWT-authenticated login — no SSH required
- Drag-and-drop file upload directly to S3 (`input/{user_id}/`)
- Job submission form with CPU / memory / time controls
- Live job status with 5-second polling
- Log viewer streaming from FSx
- Result file listing with presigned S3 download URLs
- Admin view of all users' jobs
- Per-user S3 isolation

### Stack

| Component | Technology |
|---|---|
| Backend | FastAPI + SQLite + boto3 + subprocess Slurm |
| Frontend | React 18 + Vite + Tailwind CSS |
| Proxy | nginx (reverse proxy + SPA fallback, 500 MB upload limit) |
| Runtime | Docker Compose (`network_mode: host` for Slurm socket access) |

### Setup

```bash
# On the head node
cd jobui
chmod +x setup.sh
./setup.sh
```

The script installs Docker if needed, prompts for `S3_BUCKET` and `JWT_SECRET`, configures sudoers for `sbatch`/`scancel`, and starts the stack.

### Default Credentials

> **Change these immediately in production.**

| Username | Password | Role |
|---|---|---|
| `admin` | `admin123` | Admin — sees all jobs |
| `user1` | `user1pass` | Standard user |
| `user2` | `user2pass` | Standard user |

### Key URLs

| URL | Purpose |
|---|---|
| `http://<head_node_ip>/` | Web UI |
| `http://<head_node_ip>/api/docs` | Interactive API docs (Swagger) |
| `http://<head_node_ip>/api/health` | Health check |

Full reference: [`jobui/README.md`](jobui/README.md)

---

## S3 Data Pipeline

### Flow

```
Browser / CLI             Login Node              Compute Node               S3 Bucket
─────────────             ──────────              ────────────               ─────────
Upload → input/  ──────►  sbatch job   ──────►  aws s3 cp input/ → /fsx  ──►  (download)
  (UI or aws s3 cp)                               [process on FSx]
                                                  aws s3 cp output/ → results/<job_id>/
                                                  rm -rf /fsx/work/$USER/$JOB_ID/
```

### S3 Bucket Structure

```
s3://<bucket>/
├── input/
│   └── {user_id}/          ← Web UI uploads (per-user isolation)
│       └── mydata.csv
├── input/                  ← CLI uploads (shared)
│   └── mydata.txt
└── results/
    ├── 42/                 ← One folder per Slurm job ID
    │   └── summary.txt
    └── 43/
        └── output.csv
```

### Environment Variables (available on all nodes)

| Variable | Value | Set in |
|---|---|---|
| `HPC_BUCKET` | `titan-non-prod-hpc-data-<id>` | `/etc/environment` + `/etc/profile.d/hpc-pipeline.sh` |
| `HPC_S3_INPUT` | `s3://<bucket>/input` | `/etc/profile.d/hpc-pipeline.sh` |
| `HPC_S3_RESULTS` | `s3://<bucket>/results` | `/etc/profile.d/hpc-pipeline.sh` |

### IAM S3 Permissions (scoped to cluster bucket only)

| Permission | Scope |
|---|---|
| `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `arn:aws:s3:::bucket/*` |
| `s3:ListBucket` | `arn:aws:s3:::bucket` |

All three node roles (head, compute, login) have identical S3 permissions scoped to the cluster bucket. No cross-bucket access.

### Job Script Safety Rules

- Always copy S3 input to `/fsx/work/$USER/$JOB_ID/` first — never process directly from S3
- Always use per-job directories — never write to `/fsx/work/$USER/` root
- Always clean up `/fsx/work/$USER/$JOB_ID/` at end of job
- S3 uploads include 3-attempt retry with 5s backoff

---

## Configuration

All Terraform settings are in `non-prod.tfvars`:

| Variable | Default | Description |
|---|---|---|
| `namespace` | `titan` | Prefix for all AWS resource names |
| `env` | `non-prod` | Environment tag |
| `ssh_allowed_cidr` | — | Your IP in CIDR format (`x.x.x.x/32`) |
| `head_node_instance_type` | `t3.micro` | Head node size |
| `compute_instance_type` | `t3.micro` | Compute node size |
| `max_compute_nodes` | `2` | Maximum concurrent compute nodes |
| `aws_region` | `us-east-1` | AWS region |

---

## Shared Filesystem (FSx for Lustre)

All nodes (head, login, compute) mount `/fsx` automatically at boot:

| Path | Permissions | Purpose |
|---|---|---|
| `/fsx/home/<user>` | 755 | User home on shared FS — job scripts live here |
| `/fsx/work/<user>` | 700 | Job working directory, owner only |
| `/fsx/shared` | 777 | World-writable scratch space |

Pre-created users with consistent UIDs across all nodes:

| User | UID | Use |
|---|---|---|
| `user1` | 2001 | Test user 1 |
| `user2` | 2002 | Test user 2 |

---

## Slurm Node Spec

Compute nodes are defined in `slurm.conf` as:
```
CPUs=2  RealMemory=900  State=CLOUD  ResumeTimeout=600
```
`ResumeTimeout=600` accommodates Lustre client install (~7 min) during compute node boot.

---

## Job Scripts

| File | Description |
|---|---|
| `jobs/job.sh` | Basic hello world array job (output to `/tmp`) |
| `jobs/fsx_test_job.sh` | FSx array job — writes to `/fsx/work/$USER/` |
| `jobs/s3_pipeline_job.sh` | Full S3 pipeline — S3 download → FSx compute → S3 upload → FSx cleanup |

---

## Cost

| Resource | Cost |
|---|---|
| Head node (t3.micro) | ~$0.01/hr while deployed |
| Login node (t3.small) | ~$0.02/hr while deployed |
| Compute nodes (t3.micro) | ~$0.01/hr each, only when jobs run |
| FSx SCRATCH_1 1200 GB | ~$0.14/hr (~$100/month) |
| S3 storage | ~$0.023/GB/month (negligible for test data) |

**Idle cluster cost ≈ $0.72/day** (head + login nodes only).

> **Cost warning**: FSx is the dominant ongoing cost. Run `bash destroy.sh` immediately after testing. S3 and FSx are both destroyed cleanly — no orphaned resources.

---

## Security

- SSH access restricted to `ssh_allowed_cidr` only (login node)
- Head node has no direct internet SSH — reachable only from login node
- Web UI secured with JWT — tokens expire after 8 hours
- IMDSv2 required on head and login nodes
- EBS volumes encrypted on all nodes
- S3 bucket: AES256 encryption, versioning, all public access blocked
- S3 IAM permissions scoped to cluster bucket only (no wildcard `*` resource)
- Slurm DB password randomly generated by Terraform (never hardcoded)
- Munge key generated at boot, stored encrypted in SSM Parameter Store
- No secrets in code or `.tfvars` files (gitignored)

## Login Node Enforcement

Four independent layers enforce no-compute-on-login-node policy:

| Layer | Mechanism | Effect |
|---|---|---|
| A | `/etc/security/limits.conf` | CPU time hard cap 60 min, max 400 processes |
| B | cgroups (cgconfig + cgred) | 256 CPU shares, 1 GB memory ceiling |
| C | Process watchdog (cron) | Kills any process >50% CPU for >60s |
| D | Shell policy (`/etc/profile.d/`) | `python`, `python3`, `mpirun`, `mpiexec` blocked with message |

---

## License

MIT — see [LICENSE](LICENSE).
