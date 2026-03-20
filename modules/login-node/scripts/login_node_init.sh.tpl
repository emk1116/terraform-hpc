#!/bin/bash
set -e
exec > >(tee /var/log/hpc-login-init.log) 2>&1

echo "=== HPC Login Node Init: $(date) ==="

# ── Terraform-injected config ─────────────────────────────────────────────────
NAMESPACE="${namespace}"
ENV="${env}"
REGION="${aws_region}"
CLUSTER_NAME="${namespace}-${env}"
MAX_NODES="${max_compute_nodes}"
LAST_IDX=$(( ${max_compute_nodes} - 1 ))

# ── IMDSv2 metadata ───────────────────────────────────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Login node IP: $PRIVATE_IP"

# ── Install packages ──────────────────────────────────────────────────────────
yum update -y
amazon-linux-extras install epel -y
yum install -y slurm munge munge-devel awscli libcgroup libcgroup-tools

# Create slurm user
useradd -r -d /var/lib/slurm -s /sbin/nologin slurm 2>/dev/null || true

# ── Get munge key from SSM ────────────────────────────────────────────────────
echo "Fetching munge key..."
for i in $(seq 1 40); do
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

# ── Head node info injected by Terraform (no SSM race condition) ──────────────
HEAD_NODE_IP="${head_node_private_ip}"
# Derive the EC2 internal hostname from the IP (format: ip-A-B-C-D.ec2.internal)
HEAD_NODE_HOSTNAME="ip-$(echo "$HEAD_NODE_IP" | tr '.' '-').ec2.internal"
echo "Head node: $HEAD_NODE_HOSTNAME ($HEAD_NODE_IP)"
echo "$HEAD_NODE_IP $HEAD_NODE_HOSTNAME" >> /etc/hosts

# ── Slurm client config ───────────────────────────────────────────────────────
mkdir -p /etc/slurm /var/log/slurm
chown slurm:slurm /var/log/slurm

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

SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

SlurmctldParameters=cloud_reg_addrs

NodeName=$CLUSTER_NAME-compute-[0-$LAST_IDX] CPUs=2 RealMemory=900 State=CLOUD Feature=cloud
PartitionName=main Nodes=$CLUSTER_NAME-compute-[0-$LAST_IDX] Default=YES MaxTime=INFINITE State=UP
SLURMCONF

chown slurm:slurm /etc/slurm/slurm.conf
chmod 644 /etc/slurm/slurm.conf

# Start munge (required for Slurm auth — no slurmctld/slurmd on login node)
systemctl enable munge && systemctl start munge

# ── Layer A: System resource limits ──────────────────────────────────────────
cat >> /etc/security/limits.conf << 'LIMITS'

# HPC login node — restrict non-root users
*    soft cpu    30
*    hard cpu    60
*    soft nproc  200
*    hard nproc  400
root soft cpu    unlimited
root hard cpu    unlimited
root soft nproc  unlimited
root hard nproc  unlimited
LIMITS

# Ensure pam_limits is enforced for SSH sessions
grep -q "pam_limits" /etc/pam.d/sshd || \
  echo "session    required     pam_limits.so" >> /etc/pam.d/sshd

# ── Layer B: cgroups (low-priority + memory cap for user sessions) ────────────
cat > /etc/cgconfig.conf << 'CGCONFIG'
group login_limit {
  cpu {
    cpu.shares = 256;
  }
  memory {
    memory.limit_in_bytes = 1073741824;
  }
}
CGCONFIG

cat > /etc/cgrules.conf << 'CGRULES'
# Move all non-root processes into the login_limit cgroup
*     cpu,memory    login_limit
root  cpu,memory    /
CGRULES

systemctl enable cgconfig 2>/dev/null || true
systemctl start  cgconfig 2>/dev/null || true
systemctl enable cgred    2>/dev/null || true
systemctl start  cgred    2>/dev/null || true

# ── Layer C: Process watchdog (kills >50% CPU for >60s) ──────────────────────
cat > /usr/local/bin/login-watchdog.sh << 'WATCHDOG'
#!/bin/bash
LOG=/var/log/login-watchdog.log
SYSTEM_USERS="root slurm munge"

while IFS= read -r line; do
  pid=$(echo "$line"  | awk '{print $1}')
  user=$(echo "$line" | awk '{print $2}')
  cpu=$(echo "$line"  | awk '{print $3}')
  elapsed=$(echo "$line" | awk '{print $4}')
  cmd=$(echo "$line"  | awk '{print $5}')

  skip=0
  for su in $SYSTEM_USERS; do
    [ "$user" = "$su" ] && skip=1 && break
  done
  [ "$skip" -eq 1 ] && continue

  cpu_int=$(echo "$cpu" | cut -d. -f1)
  if [ "$cpu_int" -gt 50 ] && [ "$elapsed" -gt 60 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] KILLED pid=$pid cmd=$cmd user=$user cpu=$${cpu}% elapsed=$${elapsed}s" >> $LOG
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
  fi
done < <(ps -eo pid,user,pcpu,etimes,comm --no-headers 2>/dev/null)
WATCHDOG

chmod 755 /usr/local/bin/login-watchdog.sh

cat > /etc/cron.d/login-watchdog << 'CRONENTRY'
* * * * * root /usr/local/bin/login-watchdog.sh
CRONENTRY
chmod 644 /etc/cron.d/login-watchdog

# ── Layer D: MOTD + shell policy ──────────────────────────────────────────────
# Disable AL2 dynamic MOTD scripts so our message is not overwritten
chmod -x /etc/update-motd.d/* 2>/dev/null || true

cat > /etc/motd << 'MOTD'

  ╔══════════════════════════════════════════════════════════════════╗
  ║           TITAN HPC CLUSTER  —  LOGIN NODE                      ║
  ╠══════════════════════════════════════════════════════════════════╣
  ║  This node is for job SUBMISSION only.                          ║
  ║  Do NOT run compute workloads here.                             ║
  ║                                                                 ║
  ║  Allowed : sbatch  squeue  sinfo  sacct  scontrol               ║
  ║  Blocked : Python  MPI  heavy computation  long-running tasks   ║
  ║                                                                 ║
  ║  Violations are logged. Processes are auto-terminated.          ║
  ╚══════════════════════════════════════════════════════════════════╝

MOTD

cp /etc/motd /etc/issue.net

cat > /etc/profile.d/login-node-policy.sh << 'POLICY'
#!/bin/bash

_hpc_blocked() {
  local cmd=$1
  echo "" >&2
  echo "  WARNING: '$cmd' is not permitted on the login node." >&2
  echo "  Submit your workload via: sbatch your_job.sh" >&2
  echo "" >&2
  return 1
}

python()  { _hpc_blocked python;  }
python3() { _hpc_blocked python3; }
mpirun()  { _hpc_blocked mpirun;  }
mpiexec() { _hpc_blocked mpiexec; }

export -f _hpc_blocked python python3 mpirun mpiexec
POLICY

chmod 644 /etc/profile.d/login-node-policy.sh

# Reload SSH to pick up banner
systemctl reload sshd || true

echo "=== Login Node Init Complete: $(date) ==="
