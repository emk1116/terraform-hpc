# Titan HPC Platform

Enterprise web UI for submitting and monitoring HPC jobs on a Slurm cluster with S3 integration.

## Architecture

```
                        ┌─────────────────────────────────────┐
                        │           HPC Head Node              │
                        │                                     │
  User Browser  ──────► │  Nginx :80                          │
                        │   ├─ /api/* ──► FastAPI :8000       │
                        │   └─ /     ──► React SPA            │
                        │                                     │
                        │  FastAPI Backend                    │
                        │   ├─ SQLite (jobs, users)           │
                        │   ├─ boto3 ──────────► AWS S3       │
                        │   └─ subprocess ─────► Slurm        │
                        │       (sbatch, sacct, scancel)      │
                        │                                     │
                        │  Slurm Cluster                      │
                        │   ├─ Worker Node 1 (/fsx shared)   │
                        │   ├─ Worker Node 2                  │
                        │   └─ ...                            │
                        └─────────────────────────────────────┘
```

## Prerequisites

- Amazon Linux 2 / AL2023 / Ubuntu 22.04+ on the Slurm head node
- Docker + Docker Compose v2
- Slurm `sbatch`, `sacct`, `scancel` on PATH
- AWS IAM role or credentials with S3 read/write access
- FSx for Lustre mounted at `/fsx` (optional but recommended)
- Port 80 open on the head node security group

## Quick Start

```bash
git clone <repo> /opt/hpc-ui
cd /opt/hpc-ui/jobui
chmod +x setup.sh
./setup.sh
```

The setup script will:
1. Check and optionally install Docker
2. Create `.env` from `.env.example` and prompt for S3 bucket / JWT secret
3. Configure `/etc/sudoers.d/hpc-slurm` for `sbatch` / `scancel`
4. Create `/data` for SQLite
5. Build and launch all services
6. Print access URL and credentials

## Manual Deployment

```bash
# 1. Copy and configure environment
cp backend/.env.example .env
vim .env   # Set S3_BUCKET, JWT_SECRET, etc.

# 2. Configure sudoers
sudo tee /etc/sudoers.d/hpc-slurm <<EOF
ec2-user ALL=(user1,user2) NOPASSWD: /usr/bin/sbatch, /usr/bin/scancel
EOF
sudo chmod 440 /etc/sudoers.d/hpc-slurm

# 3. Create data directory
sudo mkdir -p /data && sudo chown ec2-user:ec2-user /data

# 4. Build and start
docker compose up -d --build

# 5. Check health
curl http://localhost:8000/health
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `JWT_SECRET` | *(required)* | JWT signing secret — use `openssl rand -hex 32` |
| `JWT_EXPIRE_MINUTES` | `480` | Token lifetime in minutes (8 hours) |
| `S3_BUCKET` | *(required)* | S3 bucket name for input/output files |
| `AWS_REGION` | `us-east-1` | AWS region for S3 |
| `FSX_BASE` | `/fsx/work` | Base path for FSx Lustre work directories |
| `SLURM_PARTITION` | `main` | Slurm partition name for job submission |
| `DB_PATH` | `/data/hpc.db` | SQLite database file path |
| `DEFAULT_USERS` | `admin:admin123:user1:1,...` | Seed users: `username:password:cluster_user:is_admin` |

## API Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/auth/login` | Get JWT token |
| `GET` | `/auth/me` | Current user info |
| `POST` | `/files/upload` | Upload input file to S3 |
| `GET` | `/files` | List user's input files |
| `DELETE` | `/files/{key}` | Delete input file |
| `POST` | `/jobs` | Submit a new HPC job |
| `GET` | `/jobs` | List jobs (all if admin) |
| `GET` | `/jobs/{id}` | Get job status (refreshes from Slurm) |
| `GET` | `/jobs/{id}/logs` | Get job log from FSx |
| `GET` | `/jobs/{id}/results` | List result files (presigned URLs) |
| `DELETE` | `/jobs/{id}` | Cancel a running job |
| `GET` | `/health` | Health check |

Interactive API docs: `http://<host>/api/docs`

## Default Credentials

> **WARNING: Change these immediately in production!**

| Username | Password | Role |
|---|---|---|
| `admin` | `admin123` | Admin — can see all jobs |
| `user1` | `user1pass` | Standard user |
| `user2` | `user2pass` | Standard user |

To add users, update `DEFAULT_USERS` in `.env` and restart the backend:
```bash
DEFAULT_USERS="admin:NewPass!:user1:1,newuser:securepass:hpcuser3:0"
docker compose restart backend
```
New users are only seeded if they don't already exist in the database.

## S3 Structure

```
s3://your-bucket/
├── input/
│   └── {user_id}/
│       └── {filename}          ← uploaded via /files/upload
└── results/
    └── {job_id}/
        └── {output_files}      ← uploaded by job script
```

## Job Script

Each submitted job generates a bash script that:

1. Creates `/fsx/work/{cluster_user}/{job_id}/input` and `output` directories
2. Downloads input files from S3 using `aws s3 sync`
3. Runs your command with `$INPUT_DIR`, `$OUTPUT_DIR`, `$WORK_DIR`, `$JOB_ID` available
4. Uploads `output/` to `s3://bucket/results/{job_id}/`
5. Logs all output to `/fsx/work/{cluster_user}/{job_id}/job.log`

## Terraform Integration

This platform is designed to run on the head node of an HPC cluster provisioned with AWS ParallelCluster or Terraform. The backend uses `network_mode: host` so it can communicate with Slurm daemons directly. Ensure:

- The EC2 instance role has `s3:GetObject`, `s3:PutObject`, `s3:ListBucket`, `s3:DeleteObject` on `arn:aws:s3:::your-bucket/*`
- The head node is in a security group that allows inbound port 80
- FSx for Lustre is mounted at `/fsx` on all nodes

## Development

```bash
# Backend local dev
cd backend
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --reload --port 8000

# Frontend local dev
cd frontend
npm install
npm run dev   # proxies /api to localhost:8000
```
