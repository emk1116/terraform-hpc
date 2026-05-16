#!/bin/bash
# ============================================================================
# Titan HPC — suspend-node.sh
# Called by slurmctld with: suspend-node.sh <nodelist>
#
# Terminates the EC2 instance tagged slurm-node=<name>. The Team tag
# condition on our IAM policy ensures we can only terminate our own nodes.
# ============================================================================

set -euo pipefail

LOG=/var/log/slurm/suspend.log
TEAM_NAME="${team_name}"
AWS_REGION="${aws_region}"

log() {
    echo "[$(date -Iseconds)] $*" >> "$LOG"
}

terminate_node() {
    local node="$1"

    local instance_id
    instance_id=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:slurm-node,Values=$node" \
            "Name=tag:Team,Values=$TEAM_NAME" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        log "no running instance for $node (already terminated?)"
        return 0
    fi

    log "terminating $node → $instance_id"
    aws ec2 terminate-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" >> "$LOG" 2>&1 || {
        log "ERROR: terminate failed for $instance_id"
        return 1
    }
}

if [[ $# -lt 1 ]]; then
    log "ERROR: usage: suspend-node.sh <nodelist>"
    exit 1
fi

NODELIST="$1"
log "suspend invoked for: $NODELIST"

NODES=$(scontrol show hostnames "$NODELIST")
for node in $NODES; do
    terminate_node "$node" &
done
wait
log "suspend complete for: $NODELIST"
