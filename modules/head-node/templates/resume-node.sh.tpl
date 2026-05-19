#!/bin/bash
# ============================================================================
# Titan HPC — resume-node.sh
# Called by slurmctld with: resume-node.sh <nodelist>
#
# For each node, parses the GPU family from the node name (e.g. "h100-1x-3"
# → family "h100-1x"), looks up the matching launch template, and calls
# ec2:RunInstances. For H100 families, retries across fallback AZs on
# InsufficientInstanceCapacity.
# ============================================================================

set -euo pipefail

LOG=/var/log/slurm/resume.log
TEAM_NAME="${team_name}"
AWS_REGION="${aws_region}"

# Map of gpu_family → launch template ID (JSON, emitted by Terraform)
LAUNCH_TEMPLATES='${launch_template_ids}'

# Map of gpu_family → EC2 instance type (JSON)
INSTANCE_TYPES='${gpu_family_instance_types}'

# Map of AZ → subnet ID (for multi-AZ H100 fallback)
SUBNETS_BY_AZ='${compute_subnet_ids_by_az}'

# Primary subnet — default placement
PRIMARY_SUBNET="${primary_subnet_id}"

log() {
    echo "[$(date -Iseconds)] $*" >> "$LOG"
}

# Parse GPU family from node name.
# "t4-1" → "t4"
# "a10g-17" → "a10g"
# "h100-1x-3" → "h100-1x"
# "h100-8x-1" → "h100-8x"
parse_family() {
    local node="$1"
    # Strip trailing -<digits>
    echo "$node" | sed -E 's/-[0-9]+$//'
}

launch_node() {
    local node="$1"
    local family
    family=$(parse_family "$node")

    local lt_id
    lt_id=$(echo "$LAUNCH_TEMPLATES" | jq -r --arg f "$family" '.[$f] // empty')
    if [[ -z "$lt_id" ]]; then
        log "ERROR: no launch template for family '$family' (node $node)"
        scontrol update NodeName="$node" State=DOWN Reason="no launch template for $family"
        return 1
    fi

    local instance_type
    instance_type=$(echo "$INSTANCE_TYPES" | jq -r --arg f "$family" '.[$f] // empty')

    # Build the AZ attempt order:
    # - For H100 families, try primary AZ first, then fallback AZs
    # - For all other families, primary only
    local azs
    if [[ "$family" == h100-* ]]; then
        azs=$(echo "$SUBNETS_BY_AZ" | jq -r 'keys[]')
    else
        # Only primary AZ — derive from subnet
        azs=$(echo "$SUBNETS_BY_AZ" | jq -r 'to_entries | map(select(.value == "'"$PRIMARY_SUBNET"'")) | .[0].key')
    fi

    for az in $azs; do
        local subnet_id
        subnet_id=$(echo "$SUBNETS_BY_AZ" | jq -r --arg az "$az" '.[$az]')
        if [[ -z "$subnet_id" || "$subnet_id" == "null" ]]; then
            log "no subnet for AZ $az, skipping"
            continue
        fi

        log "launching $node as $instance_type in $az (subnet $subnet_id)"

        # Attempt RunInstances; capture stderr so we can detect capacity errors
        local output
        if output=$(aws ec2 run-instances \
            --region "$AWS_REGION" \
            --launch-template "LaunchTemplateId=$lt_id,Version=\$Latest" \
            --instance-type "$instance_type" \
            --subnet-id "$subnet_id" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$node},{Key=slurm-node,Value=$node},{Key=Team,Value=$TEAM_NAME},{Key=GpuFamily,Value=$family},{Key=Role,Value=compute}]" \
            --output json 2>&1); then
            local instance_id
            instance_id=$(echo "$output" | jq -r '.Instances[0].InstanceId')
            log "SUCCESS: $node → $instance_id in $az"
            return 0
        fi

        # Failed — check why
        if echo "$output" | grep -qE "InsufficientInstanceCapacity|InstanceLimitExceeded|Unsupported"; then
            log "capacity unavailable for $instance_type in $az, trying next AZ"
            continue
        else
            log "ERROR launching $node: $output"
            scontrol update NodeName="$node" State=DOWN Reason="launch failed: $${output:0:200}"
            return 1
        fi
    done

    log "ERROR: $node exhausted all AZs without success"
    scontrol update NodeName="$node" State=DOWN Reason="no capacity in any AZ"
    return 1
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
    log "ERROR: usage: resume-node.sh <nodelist>"
    exit 1
fi

NODELIST="$1"
log "resume invoked for: $NODELIST"

# Expand nodelist (e.g. "t4-[1-3]" → "t4-1 t4-2 t4-3")
NODES=$(scontrol show hostnames "$NODELIST")

for node in $NODES; do
    launch_node "$node" &
done

# Wait for all launch attempts to finish (but don't exit non-zero if some fail —
# Slurm will see the DOWN state and act accordingly)
wait
log "resume complete for: $NODELIST"
