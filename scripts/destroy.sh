#!/usr/bin/env bash
# Safely tear down a team cluster.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <tfvars-file>"
    echo "example: $0 team-alpha.tfvars"
    exit 1
fi

TFVARS="$1"
if [[ ! -f "$TFVARS" ]]; then
    echo "ERROR: $TFVARS not found"
    exit 1
fi

TEAM_NAME=$(grep -E '^team_name' "$TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/')
ENV=$(grep -E '^env' "$TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || echo "non-prod")

echo "About to destroy: $TEAM_NAME ($ENV)"
echo
echo "This will permanently delete:"
echo "  - VPC and all resources"
echo "  - Aurora cluster (no final snapshot if non-prod)"
echo "  - Valkey cache"
echo "  - FSx Lustre (all data)"
echo "  - S3 bucket contents (if force_destroy=true)"
echo "  - ECR images"
echo "  - All EC2 instances"
echo
read -p "Type the team name '$TEAM_NAME' to confirm: " CONFIRM

if [[ "$CONFIRM" != "$TEAM_NAME" ]]; then
    echo "aborted"
    exit 1
fi

# Step 1: terminate any running compute nodes (Slurm may have launched them)
echo "[1/4] terminating any running compute nodes..."
aws ec2 describe-instances \
    --filters "Name=tag:Team,Values=$TEAM_NAME" \
              "Name=tag:Role,Values=compute" \
              "Name=instance-state-name,Values=running,pending,stopping" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text | tr '\t' '\n' | while read -r id; do
    [[ -z "$id" ]] && continue
    echo "  terminating $id"
    aws ec2 terminate-instances --instance-ids "$id" >/dev/null
done

# Step 2: abort any stalled S3 multipart uploads
BUCKET_NAME=$(terraform output -raw s3_data_bucket 2>/dev/null || echo "")
if [[ -n "$BUCKET_NAME" ]]; then
    echo "[2/4] aborting multipart uploads in $BUCKET_NAME..."
    aws s3api list-multipart-uploads --bucket "$BUCKET_NAME" \
        --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null | \
        while read -r key upload_id; do
            [[ -z "$key" ]] && continue
            aws s3api abort-multipart-upload --bucket "$BUCKET_NAME" \
                --key "$key" --upload-id "$upload_id" >/dev/null 2>&1 || true
        done
fi

# Step 3: run terraform destroy
echo "[3/4] running terraform destroy..."
terraform destroy -var-file="$TFVARS" -auto-approve

echo "[4/4] done"
