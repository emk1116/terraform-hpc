# Snakemake fan-out demo

A 3-rule Snakemake pipeline that exercises Slurm-backed parallel scheduling on
the Titan HPC stack:

```
input/sample.fasta
        │
        ▼
   ┌─── chunk ───┐                   (local, fast)
   │             │
   ▼             ▼
inference     inference  ...  ×N    (per-chunk Slurm GPU job)
   │             │
   └──────┬──────┘
          ▼
        merge                        (local)
          │
          ▼
   results/summary.json
```

## What this tests

- Snakemake submitting many short Slurm jobs in parallel (fan-out)
- Slurm autoscaling: launches new T4 nodes on demand, suspends them when idle
- FSx as the shared workspace across all rules
- The smoke path (CUDA base image, just `nvidia-smi`) — no model weights needed
- Aggregating per-chunk results back into a single output (fan-in)

## Setup (once, after `terraform apply`)

```bash
# SSM into the login node (preferred for Snakemake)
aws ssm start-session --target $(terraform output -raw login_node_public_ip || \
                                terraform output -raw head_node_instance_id)

# On the node:
sudo dnf install -y python3-pip
pip3 install --user snakemake snakemake-executor-plugin-slurm

# Stage the demo onto FSx (so all compute nodes can see it)
sudo mkdir -p /fsx/shared/snakemake-demo
sudo cp -r /opt/titan-hpc/examples/snakemake-demo/* /fsx/shared/snakemake-demo/
sudo chmod -R 777 /fsx/shared/snakemake-demo
```

(If `/opt/titan-hpc/examples` isn't on the node, copy from your laptop via
`aws s3 cp --recursive examples/snakemake-demo s3://<bucket>/demo/` and pull
on the node.)

## Run

```bash
cd /fsx/shared/snakemake-demo
snakemake --profile slurm --jobs 5
```

Expected: 5 Slurm jobs queue, Slurm autoscales 1–4 T4 nodes (depending on
warm capacity), each chunk runs `nvidia-smi` in a CUDA container, and the
`merge` rule produces `results/summary.json`.

## Tuning

- `DEMO_N_CHUNKS=10 snakemake --profile slurm --jobs 5` — 10 chunks, max 5 in flight
- `DEMO_INFER_IMAGE=<your-ecr-uri> snakemake ...` — swap in a real model
- Edit `slurm/config.yaml` to change defaults

## Cost

5 chunks × ~3 min each on T4 (`g4dn.xlarge`, $0.526/hr) ≈ **$0.13** in compute,
assuming nodes warm-start. First run usually adds ~$0.10 for node boot time.
