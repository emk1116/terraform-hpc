#!/bin/bash
set -e
exec > >(tee /var/log/hpc-compute-init.log) 2>&1

echo "=== HPC Compute Node Init: $(date) ==="

# ── Terraform-injected config ─────────────────────────────────────────────────
NAMESPACE="${namespace}"
ENV="${env}"
REGION="${aws_region}"
CLUSTER_NAME="${namespace}-${env}"
MAX_NODES="${max_compute_nodes}"
LAST_IDX=$(( ${max_compute_nodes} - 1 ))

# ── IMDSv1 metadata (compute nodes use optional IMDSv2) ───────────────────────
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Instance: $INSTANCE_ID | IP: $PRIVATE_IP | Cluster: $CLUSTER_NAME"

# ── Get Slurm node name from instance tag ─────────────────────────────────────
echo "Fetching SlurmNodeName tag..."
for i in $(seq 1 30); do
  NODE_NAME=$(aws ec2 describe-tags \
    --region "$REGION" \
    --filters \
      "Name=resource-id,Values=$INSTANCE_ID" \
      "Name=key,Values=SlurmNodeName" \
    --query 'Tags[0].Value' \
    --output text 2>/dev/null)
  if [ -n "$NODE_NAME" ] && [ "$NODE_NAME" != "None" ]; then
    echo "Got node name: $NODE_NAME"
    break
  fi
  echo "Waiting for tag... attempt $i"
  sleep 5
done

if [ -z "$NODE_NAME" ] || [ "$NODE_NAME" = "None" ]; then
  echo "ERROR: Could not get SlurmNodeName tag. Exiting."
  exit 1
fi

# ── Set hostname ──────────────────────────────────────────────────────────────
hostnamectl set-hostname "$NODE_NAME"

# ── Install packages ──────────────────────────────────────────────────────────
yum update -y
amazon-linux-extras install epel -y
amazon-linux-extras install lustre7 -y
yum install -y slurm slurm-slurmd munge munge-devel awscli

# Create slurm user (AL2 EPEL RPM does not always create it automatically)
useradd -r -d /var/lib/slurm -s /sbin/nologin slurm 2>/dev/null || true

# Create cluster users with consistent UIDs (must match head and login nodes)
useradd -u 2001 -m -s /bin/bash user1 2>/dev/null || true
useradd -u 2002 -m -s /bin/bash user2 2>/dev/null || true

# ── Get munge key from SSM ────────────────────────────────────────────────────
echo "Fetching munge key from SSM..."
for i in $(seq 1 20); do
  MUNGE_KEY_B64=$(aws ssm get-parameter \
    --region "$REGION" \
    --name "/hpc/$NAMESPACE/$ENV/munge-key" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null)
  if [ -n "$MUNGE_KEY_B64" ] && [ "$MUNGE_KEY_B64" != "None" ]; then
    echo "Got munge key"
    break
  fi
  echo "Waiting for munge key... attempt $i"
  sleep 10
done

echo "$MUNGE_KEY_B64" | base64 -d > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

# ── Get head node info from SSM ───────────────────────────────────────────────
HEAD_NODE_IP=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/hpc/$NAMESPACE/$ENV/head-node-ip" \
  --query 'Parameter.Value' --output text)

HEAD_NODE_HOSTNAME=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/hpc/$NAMESPACE/$ENV/head-node-hostname" \
  --query 'Parameter.Value' --output text)

echo "Head node: $HEAD_NODE_HOSTNAME ($HEAD_NODE_IP)"

# ── Update /etc/hosts ─────────────────────────────────────────────────────────
echo "$HEAD_NODE_IP $HEAD_NODE_HOSTNAME" >> /etc/hosts

# ── Slurm directories ─────────────────────────────────────────────────────────
mkdir -p /etc/slurm /var/spool/slurmd /var/log/slurm
chown slurm:slurm /var/spool/slurmd /var/log/slurm

# ── slurm.conf ────────────────────────────────────────────────────────────────
cat > /etc/slurm/slurm.conf << SLURMCONF
ClusterName=$CLUSTER_NAME
SlurmctldHost=$HEAD_NODE_HOSTNAME

AuthType=auth/munge
CryptoType=crypto/munge
MpiDefault=none
ProctrackType=proctrack/pgid
ReturnToService=2
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld
SwitchType=switch/none
TaskPlugin=task/none

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU_Memory

AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=$HEAD_NODE_IP
AccountingStoragePort=6819
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=30

SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmdDebug=info

SlurmctldParameters=cloud_reg_addrs

NodeName=$CLUSTER_NAME-compute-[0-$LAST_IDX] CPUs=2 RealMemory=900 State=CLOUD Feature=cloud
PartitionName=main Nodes=$CLUSTER_NAME-compute-[0-$LAST_IDX] Default=YES MaxTime=INFINITE State=UP
SLURMCONF

chown slurm:slurm /etc/slurm/slurm.conf

# ── FSx for Lustre mount ──────────────────────────────────────────────────────
FSX_DNS="${fsx_dns_name}"
FSX_MOUNT="${fsx_mount_name}"

mkdir -p /fsx

echo "Mounting FSx for Lustre..."
for i in $(seq 1 20); do
  mount -t lustre -o noatime,flock "$FSX_DNS@tcp:/$FSX_MOUNT" /fsx && echo "FSx mounted" && break
  echo "FSx mount attempt $i/20 failed, retrying in 15s..."
  sleep 15
done

# Persist in fstab
if ! grep -q "$FSX_DNS" /etc/fstab; then
  echo "$FSX_DNS@tcp:/$FSX_MOUNT  /fsx  lustre  defaults,noatime,flock,_netdev  0 0" >> /etc/fstab
fi

# ── Update node address in slurmctld ─────────────────────────────────────────
# slurmd will auto-register the node address when cloud_reg_addrs is set

# ── Start services ────────────────────────────────────────────────────────────
systemctl enable munge && systemctl start munge

systemctl enable slurmd && systemctl start slurmd

echo "=== Compute Node $NODE_NAME Init Complete: $(date) ==="
