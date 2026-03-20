# Titan HPC Cluster

Production-style HPC cluster on AWS using Slurm with autoscaling compute nodes, shared FSx for Lustre storage, and an S3-backed data pipeline — deployed entirely via Terraform.

## Architecture

```
                        Internet
                            │
                  SSH (your IP only)    aws s3 cp (input)
                            │                  │
              ┌─────────────▼──────────────┐   │
              │         Login Node          │   │
              │         (t3.small)          │◄──┘
              │                             │
              │  • Job submission only      │
              │  • sbatch / squeue / sinfo  │
              │  • aws s3 cp (upload input) │
              │  • CPU/memory enforced      │
              └─────────────┬───────────────┘
                            │ SSH (private)
          ┌─────────────────▼─────────────────────────────┐
          │                  AWS VPC                       │
          │                                                │
          │  ┌──────────────────┐                          │
          │  │    Head Node     │                          │
          │  │    (t3.micro)    │◄── Slurm RPC             │
          │  │  • slurmctld     │                          │
          │  │  • slurmdbd      │                          │
          │  │  • MariaDB       │                          │
          │  │  • resume.sh     │                          │
          │  │  • suspend.sh    │                          │
          │  └────────┬─────────┘                          │
          │           │ ec2:RunInstances                   │
          │  ┌────────▼──────────────────┐                 │
          │  │     Compute Nodes         │                 │
          │  │  (t3.micro × 0–N)         │                 │
          │  │                           │                 │
          │  │  • slurmd                 │◄─── S3 input    │
          │  │  • munge                  │────► S3 results │
          │  │  • aws s3 cp              │                 │
          │  │  Launched on job submit   │                 │
          │  │  Terminated after idle    │                 │
          │  └───────────┬───────────────┘                 │
          │              │ mount /fsx                      │
          │  ┌───────────▼───────────────┐                 │
          │  │   FSx for Lustre (1.2TB)  │                 │
          │  │                           │                 │
          │  │  /fsx/home/<user>  (755)  │                 │
          │  │  /fsx/work/<user>  (700)  │                 │
          │  │  /fsx/shared       (777)  │                 │
          │  │  Mounted on all nodes     │                 │
          │  └───────────────────────────┘                 │
          └────────────────────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │   S3 Data Bucket      │
                    │                       │
                    │  input/               │◄── User uploads
                    │  results/<job_id>/    │──► Job output
                    │                       │
                    │  • AES256 encrypted   │
                    │  • Versioning on      │
                    │  • No public access   │
                    └───────────────────────┘
```

**Autoscaling**: Slurm's `ResumeProgram` launches EC2 instances when jobs are queued. `SuspendProgram` terminates them after 120 seconds idle. No compute instances run when the cluster is idle.

**Login node enforcement**: Four independent layers prevent heavy jobs from running on the login node — PAM limits, cgroups, process watchdog, and shell policy overrides.

**S3 pipeline**: Jobs download input from S3 to FSx, process locally, upload results back to S3 under `results/<job_id>/`, then clean up FSx. No data persists on FSx between jobs.

## Modules

| Module | Purpose |
|---|---|
| `network` | VPC, subnet, IGW, route table, login SG + HPC SG |
| `iam` | IAM roles and instance profiles (head, compute, login) — includes S3 scoped access |
| `head-node` | Head node EC2, EIP, Slurm controller + accounting |
| `login-node` | Login node EC2, EIP, job submission enforcement |
| `compute-fleet` | Launch template and ASG for compute nodes |
| `fsx` | FSx for Lustre SCRATCH_1 shared filesystem |
| `s3` | S3 data bucket with encryption, versioning, and public access block |

## Prerequisites

- Terraform >= 1.14.7
- AWS CLI configured (`aws configure`)
- An SSH key pair

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

**4. Connect (login node is your only entry point)**
```bash
ssh -i ~/.ssh/titan-hpc ec2-user@<login_node_public_ip>
```

**5. Run the S3 pipeline**
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

**6. Run the FSx test job (no S3 required)**
```bash
sudo -u user1 sbatch /fsx/home/user1/fsx_test_job.sh
squeue
sudo ls /fsx/work/user1/
cat /fsx/shared/fsx_test.log
```

**7. Destroy everything**
```bash
bash destroy.sh
```
> Compute nodes, FSx, and S3 bucket (including all data) are fully destroyed. No charges remain.

## S3 Data Pipeline

### Flow

```
Local machine                Login Node              Compute Node               S3 Bucket
─────────────                ──────────              ────────────               ─────────
aws s3 cp → input/    ──►    sbatch job    ──►    aws s3 cp input/ → /fsx    ──►  (download)
                                                   [process on FSx]
                                                   aws s3 cp output/ → results/<job_id>/
                                                   rm -rf /fsx/work/$USER/$JOB_ID/
```

### S3 Bucket Structure

```
s3://<bucket>/
├── input/              ← Upload your data here before submitting
│   ├── mydata.txt
│   └── model.dat
└── results/
    ├── 42/             ← One folder per job ID
    │   └── summary.txt
    └── 43/
        └── summary.txt
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

## Configuration

All settings are in your `non-prod.tfvars`:

| Variable | Default | Description |
|---|---|---|
| `namespace` | `titan` | Prefix for all AWS resource names |
| `env` | `non-prod` | Environment tag |
| `ssh_allowed_cidr` | — | Your IP in CIDR format (`x.x.x.x/32`) |
| `head_node_instance_type` | `t3.micro` | Head node size |
| `compute_instance_type` | `t3.micro` | Compute node size |
| `max_compute_nodes` | `2` | Maximum concurrent compute nodes |
| `aws_region` | `us-east-1` | AWS region |

## Shared Filesystem (FSx for Lustre)

All nodes (head, login, compute) mount `/fsx` automatically at boot:

| Path | Permissions | Purpose |
|---|---|---|
| `/fsx/home/<user>` | 755 | User home on shared FS |
| `/fsx/work/<user>` | 700 | Job working directory, owner only |
| `/fsx/shared` | 777 | World-writable scratch space |

Pre-created users with consistent UIDs across all nodes:

| User | UID | Use |
|---|---|---|
| `user1` | 2001 | Test user 1 |
| `user2` | 2002 | Test user 2 |

Use `sudo -u user1 sbatch ...` to submit jobs as a cluster user.

## Slurm Node Spec

Compute nodes are defined in `slurm.conf` as:
```
CPUs=2  RealMemory=900  State=CLOUD  ResumeTimeout=600
```
`ResumeTimeout=600` accommodates Lustre client install (~7 min) during compute node boot.

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

## Security

- SSH access restricted to `ssh_allowed_cidr` only (login node)
- Head node has no direct internet SSH — reachable only from login node
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

## Jobs

| File | Description |
|---|---|
| `jobs/job.sh` | Basic hello world array job (output to `/tmp`) |
| `jobs/fsx_test_job.sh` | FSx array job — writes to `/fsx/work/$USER/` |
| `jobs/s3_pipeline_job.sh` | Full S3 pipeline — S3 download → FSx compute → S3 upload → FSx cleanup |

## License

MIT — see [LICENSE](LICENSE).
