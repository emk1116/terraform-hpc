# Example: Evo2-style inference container

Minimal reference container demonstrating the titan-hpc "thin container" pattern.

## What this shows

- **No weights baked in** — the container is ~3 GB, not 40 GB
- **Weights mounted at `/models` from FSx** — set at `docker run` time
- **Standard CLI contract** — `--weights`, `--input`, `--output` flags matching what the models catalog and job script template expect
- **GPU verification** — fails loudly if `--gpus all` isn't set

## Build and push

```bash
REGION=us-east-1
TEAM=alpha
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
REPO="$TEAM/models/evo2"

aws ecr get-login-password --region $REGION | \
    docker login --username AWS --password-stdin $REGISTRY

docker buildx build --platform linux/amd64 \
    -t "$REGISTRY/$REPO:v0.1.0" --push .
```

## Register in the catalog

```bash
curl -X POST https://<alb-host>/api/models \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "model_key": "evo2-demo",
      "display_name": "Evo2 demo (smoke test)",
      "ecr_uri": "'$REGISTRY/$REPO':v0.1.0",
      "weights_path": "/fsx/models/evo2-demo/mock-weights.pt",
      "gpu_min_memory_gb": 4,
      "allowed_gpus": ["t4", "a10g", "l4", "h100-1x"],
      "default_runtime_hours": 1,
      "max_runtime_hours": 2
    }'
```

## Stage mock weights

This example doesn't use real weights; create a placeholder:

```bash
# On head node
sudo mkdir -p /fsx/models/evo2-demo
sudo sh -c 'dd if=/dev/urandom of=/fsx/models/evo2-demo/mock-weights.pt bs=1M count=100'
sudo chmod -R a+r /fsx/models/evo2-demo
```

## Submit a test job

Upload any text file from the UI, pick T4 + "Evo2 demo (smoke test)", submit. Should complete in <2 minutes and produce `predictions.json` and `summary.txt` in the results.
