#!/usr/bin/env bash
# Stage model weights from S3 to FSx /fsx/models/<model_key>/
#
# Usage: stage-model-weights.sh <model_key> <s3_source_prefix>
#
# Example:
#   stage-model-weights.sh evo2-7b-v1 s3://my-model-store/evo2/7b/v1/
#
# Run on the head node via SSM Session Manager:
#   aws ssm start-session --target <head-instance-id>
#   sudo /opt/titan-hpc/bin/stage-model-weights.sh ...
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <model_key> <s3_source_prefix>"
    exit 1
fi

MODEL_KEY="$1"
S3_SRC="$2"
DEST="/fsx/models/$MODEL_KEY"

if [[ ! -d "/fsx" ]] || ! mountpoint -q /fsx; then
    echo "ERROR: /fsx is not mounted"
    exit 1
fi

mkdir -p "$DEST"

echo "staging $S3_SRC → $DEST"
# s5cmd is much faster than aws s3 sync for multi-GB files
if command -v s5cmd >/dev/null; then
    s5cmd cp "$S3_SRC*" "$DEST/"
else
    aws s3 sync "$S3_SRC" "$DEST/"
fi

chmod -R a+r "$DEST"
echo "done. Contents:"
ls -lah "$DEST"
echo
echo "Register this model in the UI with weights_path = $DEST/<weights-filename>"
