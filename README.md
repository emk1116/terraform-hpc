# Titan HPC Cluster

Production-style HPC cluster on AWS using Slurm with autoscaling compute nodes and shared FSx for Lustre storage, deployed entirely via Terraform.

## Architecture

```
                        Internet
                            │
                     SSH (your IP only)
                            │
              ┌─────────────▼──────────────┐
              │         Login Node          │
              │         (t3.small)          │
              │                             │
              │  • Job submission only      │
              │  • sbatch / squeue / sinfo  │
              │  • CPU/memory enforced      │
              │  • Process watchdog         │
              └─────────────┬───────────────┘
                            │ SSH (private)
          ┌─────────────────▼───────────────────┐
          │               AWS VPC                │
          │                                      │
          │  ┌──────────────────┐                │
          │  │    Head Node     │                │
          │  │    (t3.micro)    │                │
          │  │                  │◄── Slurm RPC   │
          │  │  • slurmctld     │                │
          │  │  • slurmdbd      │                │
          │  │  • MariaDB       │                │
          │  │  • resume.sh     │                │
          │  │  • suspend.sh    │                │
          │  └────────┬─────────┘                │
          │           │ ec2:RunInstances          │
          │  ┌────────▼──────────────────┐        │
          │  │     Compute Nodes         │        │
          │  │  (t3.micro × 0–2)         │        │
          │  │                           │        │
          │  │  • slurmd                 │        │
          │  │  • munge                  │        │
          │  │  Launched on job submit   │        │
          │  │  Terminated after idle    │        │
          │  └───────────────────────────┘        │
          │                                      │
          │  ┌───────────────────────────┐        │
          │  │   FSx for Lustre (1.2TB)  │        │
          │  │                           │        │
          │  │  /fsx/home/<user>  (755)  │        │
          │  │  /fsx/work/<user>  (700)  │        │
          │  │  /fsx/shared       (777)  │        │
          │  │                           │        │
          │  │  Mounted on all nodes     │        │
          │  └───────────────────────────┘        │
          └──────────────────────────────────────┘
```

**Autoscaling**: Slurm's `ResumeProgram` launches EC2 instances when jobs are queued. `SuspendProgram` terminates them after 120 seconds idle. No compute instances run when the cluster is idle.

**Login node enforcement**: Four independent layers prevent heavy jobs from running on the login node — PAM limits, cgroups, process watchdog, and shell policy overrides.

## Modules

| Module | Purpose |
|---|---|
| `network` | VPC, subnet, IGW, route table, login SG + HPC SG |
| `iam` | IAM roles and instance profiles (head, compute, login) |
| `head-node` | Head node EC2, EIP, Slurm controller + accounting |
| `login-node` | Login node EC2, EIP, job submission enforcement |
| `compute-fleet` | Launch template and ASG for compute nodes |
| `fsx` | FSx for Lustre SCRATCH_1 shared filesystem |

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
> FSx takes ~5 minutes to become available. Full init takes ~10 minutes.

**4. Connect (login node is your only entry point)**
```bash
ssh -i ~/.ssh/titan-hpc ec2-user@<login_node_public_ip>
```

**5. Submit jobs**
```bash
# Submit as a cluster user
sudo -u user1 sbatch /home/ec2-user/fsx_test_job.sh

# Monitor
squeue
sinfo

# Check results on shared FSx
ls /fsx/work/user1/
cat /fsx/shared/fsx_test.log
```

**6. Destroy**
```bash
bash destroy.sh
```
> Compute nodes launched by Slurm are automatically terminated before VPC teardown.
> FSx is also destroyed — no charges remain after destroy.

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
| `/fsx/work/<user>` | 700 | Job output, owner only |
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
CPUs=2  RealMemory=900  State=CLOUD
```
Adjust these in the init script template if you change instance type.

## Cost

| Resource | Cost |
|---|---|
| Head node (t3.micro) | ~$0.01/hr while deployed |
| Login node (t3.small) | ~$0.02/hr while deployed |
| Compute nodes (t3.micro) | ~$0.01/hr each, only when jobs run |
| FSx SCRATCH_1 1200 GB | ~$0.14/hr (~$100/month) |

**Idle cluster cost ≈ $0.72/day** (head + login nodes, no FSx data transfer).

> **Cost warning**: FSx is the largest ongoing expense. Always run `bash destroy.sh` when done testing.

## Security

- SSH access restricted to `ssh_allowed_cidr` only (login node)
- Head node has no direct internet SSH — reachable only from login node
- IMDSv2 required on head and login nodes
- EBS volumes encrypted on all nodes
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

## License

MIT — see [LICENSE](LICENSE).
