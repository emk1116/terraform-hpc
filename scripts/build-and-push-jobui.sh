#!/usr/bin/env bash
# Build the jobui backend and frontend Docker images and push to the team's ECR.
# Run this AFTER terraform apply has created the ECR repos but BEFORE the head
# node boots (or re-run to update).
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <tfvars-file>"
    exit 1
fi

TFVARS="$1"
TEAM_NAME=$(grep -E '^team_name' "$TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/')
ENV=$(grep -E '^env' "$TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || echo "non-prod")
REGION=$(grep -E '^aws_region' "$TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || echo "us-east-1")

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# We need the repos to exist. They come from the ecr module with names like:
#   <team>/models/generic, <team>/models/evo2, <team>/models/esmfold
# For jobui itself we need platform/jobui-backend and platform/jobui-frontend.

JOBUI_BACKEND_REPO="$TEAM_NAME/platform/jobui-backend"
JOBUI_FRONTEND_REPO="$TEAM_NAME/platform/jobui-frontend"

# Ensure repos exist (idempotent)
for repo in "$JOBUI_BACKEND_REPO" "$JOBUI_FRONTEND_REPO"; do
    if ! aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1; then
        echo "creating repo $repo"
        aws ecr create-repository \
            --repository-name "$repo" \
            --image-tag-mutability MUTABLE \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 \
            --region "$REGION" >/dev/null
    fi
done

echo "logging in to ECR ($REGISTRY)"
aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "$REGISTRY"

# --- Backend ---
echo "building backend..."
docker build -t "$REGISTRY/$JOBUI_BACKEND_REPO:latest" jobui/backend/
docker push "$REGISTRY/$JOBUI_BACKEND_REPO:latest"

# --- Frontend ---
echo "building frontend..."
docker build -t "$REGISTRY/$JOBUI_FRONTEND_REPO:latest" jobui/frontend/
docker push "$REGISTRY/$JOBUI_FRONTEND_REPO:latest"

echo "done"
echo "  backend:  $REGISTRY/$JOBUI_BACKEND_REPO:latest"
echo "  frontend: $REGISTRY/$JOBUI_FRONTEND_REPO:latest"
