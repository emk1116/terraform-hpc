#!/bin/bash
set -e
exec > >(tee /var/log/hpc-init.log) 2>&1

echo "=== HPC Head Node Init: $(date) ==="

# ── Terraform-injected config ─────────────────────────────────────────────────
NAMESPACE="${namespace}"
ENV="${env}"
REGION="${aws_region}"
CLUSTER_NAME="${namespace}-${env}"
LT_NAME="${launch_template_name}"
MAX_NODES="${max_compute_nodes}"
LAST_IDX=$(( ${max_compute_nodes} - 1 ))
HPC_BUCKET="${bucket_name}"

echo "Cluster: $CLUSTER_NAME | Region: $REGION | Max nodes: $MAX_NODES"

# ── IMDSv2 metadata ───────────────────────────────────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
HOSTNAME=$(hostname)

echo "Private IP: $PRIVATE_IP | Hostname: $HOSTNAME"

# ── Install packages ──────────────────────────────────────────────────────────
yum update -y
amazon-linux-extras install epel -y
amazon-linux-extras install lustre2.10 -y
yum install -y \
  slurm slurm-slurmctld slurm-slurmdbd \
  munge munge-devel \
  mariadb mariadb-server \
  awscli jq

# Create slurm user (AL2 EPEL RPM does not always create it automatically)
useradd -r -d /var/lib/slurm -s /sbin/nologin slurm 2>/dev/null || true

# Create cluster users with consistent UIDs (must match compute and login nodes)
useradd -u 2001 -m -s /bin/bash user1 2>/dev/null || true
useradd -u 2002 -m -s /bin/bash user2 2>/dev/null || true

# ── MariaDB setup ─────────────────────────────────────────────────────────────
systemctl enable mariadb
systemctl start mariadb

echo "Waiting for MariaDB to be ready..."
for i in $(seq 1 30); do
  mysql -e "SELECT 1" 2>/dev/null && break
  echo "MariaDB not ready, attempt $i/30..."
  sleep 3
done

mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;"
mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost' IDENTIFIED BY '${slurm_db_password}';"
mysql -e "FLUSH PRIVILEGES;"

# ── Munge key ─────────────────────────────────────────────────────────────────
dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

# Store in SSM for compute nodes
MUNGE_KEY_B64=$(base64 -w 0 /etc/munge/munge.key)
aws ssm put-parameter --region "$REGION" \
  --name "/hpc/$NAMESPACE/$ENV/munge-key" \
  --value "$MUNGE_KEY_B64" \
  --type SecureString --overwrite

# ── Store head node info in SSM ───────────────────────────────────────────────
aws ssm put-parameter --region "$REGION" \
  --name "/hpc/$NAMESPACE/$ENV/head-node-ip" \
  --value "$PRIVATE_IP" --type String --overwrite

aws ssm put-parameter --region "$REGION" \
  --name "/hpc/$NAMESPACE/$ENV/head-node-hostname" \
  --value "$HOSTNAME" --type String --overwrite

# ── Slurm directories ─────────────────────────────────────────────────────────
mkdir -p /etc/slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chown slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chmod 755 /var/spool/slurmctld /var/spool/slurmd /var/log/slurm

# ── slurmdbd.conf ─────────────────────────────────────────────────────────────
cat > /etc/slurm/slurmdbd.conf << DDBCONF
DbdHost=localhost
DbdPort=6819
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurmdbd.pid
SlurmUser=slurm
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=${slurm_db_password}
StorageLoc=slurm_acct_db
DDBCONF

chown slurm:slurm /etc/slurm/slurmdbd.conf
chmod 600 /etc/slurm/slurmdbd.conf

# ── slurm.conf ────────────────────────────────────────────────────────────────
cat > /etc/slurm/slurm.conf << SLURMCONF
ClusterName=$CLUSTER_NAME
SlurmctldHost=$HOSTNAME

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

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU_Memory

# Accounting
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
AccountingStoragePort=6819
AccountingStorageTRES=cpu,mem
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=30

# Logging
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

# Autoscaling (power save)
ResumeProgram=/etc/slurm/resume.sh
SuspendProgram=/etc/slurm/suspend.sh
ResumeTimeout=600
SuspendTime=120
ResumeRate=0
SuspendRate=0
SlurmctldParameters=cloud_reg_addrs

# Cloud nodes
NodeName=$CLUSTER_NAME-compute-[0-$LAST_IDX] CPUs=2 RealMemory=900 State=CLOUD Feature=cloud

# Partitions
PartitionName=main Nodes=$CLUSTER_NAME-compute-[0-$LAST_IDX] Default=YES MaxTime=INFINITE State=UP
SLURMCONF

chown slurm:slurm /etc/slurm/slurm.conf
chmod 644 /etc/slurm/slurm.conf

# ── Cluster env file (used by resume/suspend) ─────────────────────────────────
cat > /etc/slurm/cluster.env << ENVFILE
NAMESPACE=$NAMESPACE
ENV=$ENV
REGION=$REGION
CLUSTER_NAME=$CLUSTER_NAME
LT_NAME=$LT_NAME
ENVFILE

chmod 644 /etc/slurm/cluster.env

# ── Pipeline environment (available to all sessions + batch jobs) ─────────────
grep -q "HPC_BUCKET" /etc/environment || echo "HPC_BUCKET=$HPC_BUCKET" >> /etc/environment

cat > /etc/profile.d/hpc-pipeline.sh << PIPELINEENV
export HPC_BUCKET="$HPC_BUCKET"
export HPC_S3_INPUT="s3://$HPC_BUCKET/input"
export HPC_S3_RESULTS="s3://$HPC_BUCKET/results"
PIPELINEENV
chmod 644 /etc/profile.d/hpc-pipeline.sh

# ── resume.sh ─────────────────────────────────────────────────────────────────
cat > /etc/slurm/resume.sh << 'RESSCRIPT'
#!/bin/bash
export AWS_PAGER=''
exec >> /var/log/slurm/resume.log 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ResumeProgram: $1"
source /etc/slurm/cluster.env
NODES=$(scontrol show hostnames "$1")
for NODE in $NODES; do
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Launching: $NODE"
  aws ec2 run-instances \
    --region "$REGION" \
    --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
    --count 1 \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NODE},{Key=SlurmNodeName,Value=$NODE},{Key=Namespace,Value=$NAMESPACE},{Key=Environment,Value=$ENV},{Key=Project,Value=hpc},{Key=ManagedBy,Value=slurm}]"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Launched: $NODE"
done
RESSCRIPT

# ── suspend.sh ────────────────────────────────────────────────────────────────
cat > /etc/slurm/suspend.sh << 'SUSSCRIPT'
#!/bin/bash
export AWS_PAGER=''
exec >> /var/log/slurm/suspend.log 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] SuspendProgram: $1"
source /etc/slurm/cluster.env
NODES=$(scontrol show hostnames "$1")
for NODE in $NODES; do
  INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:SlurmNodeName,Values=$NODE" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Terminating $INSTANCE_ID for $NODE"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No instance for $NODE"
  fi
done
SUSSCRIPT

chmod 755 /etc/slurm/resume.sh /etc/slurm/suspend.sh
chown slurm:slurm /etc/slurm/resume.sh /etc/slurm/suspend.sh

# ── Start services ────────────────────────────────────────────────────────────
systemctl enable munge && systemctl start munge

systemctl enable slurmdbd && systemctl start slurmdbd
echo "Waiting for slurmdbd..."
for i in $(seq 1 30); do
  systemctl is-active --quiet slurmdbd && echo "slurmdbd ready" && break
  sleep 3
done

systemctl enable slurmctld && systemctl start slurmctld
echo "Waiting for slurmctld..."
for i in $(seq 1 30); do
  systemctl is-active --quiet slurmctld && echo "slurmctld ready" && break
  sleep 3
done

# ── Initialize accounting ─────────────────────────────────────────────────────
sleep 15
sacctmgr -i add cluster $CLUSTER_NAME 2>/dev/null || true
sacctmgr -i add account default Description="Default" Organization="HPC" 2>/dev/null || true
sacctmgr -i add user ec2-user DefaultAccount=default AdminLevel=Admin 2>/dev/null || true
sacctmgr -i add user user1 DefaultAccount=default 2>/dev/null || true
sacctmgr -i add user user2 DefaultAccount=default 2>/dev/null || true

# ── FSx for Lustre mount ──────────────────────────────────────────────────────
FSX_DNS="${fsx_dns_name}"
FSX_MOUNT="${fsx_mount_name}"

mkdir -p /fsx

echo "Mounting FSx for Lustre (${fsx_dns_name})..."
for i in $(seq 1 20); do
  mount -t lustre -o noatime,flock "$FSX_DNS@tcp:/$FSX_MOUNT" /fsx && echo "FSx mounted" && break
  echo "FSx mount attempt $i/20 failed, retrying in 15s..."
  sleep 15
done

# Persist in fstab
if ! grep -q "$FSX_DNS" /etc/fstab; then
  echo "$FSX_DNS@tcp:/$FSX_MOUNT  /fsx  lustre  defaults,noatime,flock,_netdev  0 0" >> /etc/fstab
fi

# ── Create multi-user directory structure on FSx ──────────────────────────────
mkdir -p /fsx/home /fsx/work /fsx/shared
chmod 755 /fsx/home /fsx/work
chmod 777 /fsx/shared

for u in user1 user2; do
  mkdir -p /fsx/home/$u /fsx/work/$u
  chown $u:$u /fsx/home/$u /fsx/work/$u
  chmod 700 /fsx/work/$u
  chmod 755 /fsx/home/$u
done

echo "FSx directory structure ready."
echo "=== Head Node Init Complete: $(date) ==="
