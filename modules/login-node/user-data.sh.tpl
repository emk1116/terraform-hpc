#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/titan-login-bootstrap.log) 2>&1

echo "[$(date)] titan-hpc login node bootstrap starting"

dnf update -y
dnf install -y jq awscli lustre-client || true

# FSx
mkdir -p /fsx
echo "${fsx_dns_name}@tcp:/${fsx_mount_name} /fsx lustre defaults,noatime,flock,_netdev 0 0" >> /etc/fstab
for i in 1 2 3 4 5; do
    if mount -a && mountpoint -q /fsx; then break; fi
    sleep 15
done

# ----------------------------------------------------------------------------
# Login node enforcement — prevent heavy jobs on the login node itself.
# Four layers, same as base repo but modernized.
# ----------------------------------------------------------------------------

# Layer A: PAM limits — CPU time hard cap 60 min, max processes 400
cat >> /etc/security/limits.conf <<'EOF'
# Titan HPC login node limits
*  hard  cpu    60
*  hard  nproc  400
*  soft  nproc  200
EOF

# Layer B: cgroups — 256 CPU shares, 1 GB memory
dnf install -y systemd-resolved || true
mkdir -p /etc/systemd/system/user-.slice.d
cat > /etc/systemd/system/user-.slice.d/titan-limits.conf <<'EOF'
[Slice]
CPUQuota=25%
MemoryMax=1G
TasksMax=400
EOF
systemctl daemon-reload

# Layer C: Process watchdog — kills any user process >50% CPU for >60s
cat > /usr/local/bin/titan-watchdog.sh <<'EOF'
#!/bin/bash
# Kill user processes sustained >50% CPU for >60s
LOG=/var/log/titan-watchdog.log
PIDS=$(ps -eo pid,pcpu,comm,user --sort=-pcpu | \
    awk 'NR > 1 && $2 > 50 && $4 != "root" && $4 != "slurm" && $4 != "munge" {print $1":"$3":"$4}')
for entry in $PIDS; do
    pid=$(echo $entry | cut -d: -f1)
    cmd=$(echo $entry | cut -d: -f2)
    user=$(echo $entry | cut -d: -f3)
    # Check if still high after 60s
    sleep 60
    if ps -p "$pid" -o pcpu= 2>/dev/null | awk '$1 > 50 {exit 0} {exit 1}'; then
        kill -TERM "$pid" 2>/dev/null && \
            echo "[$(date)] killed pid=$pid cmd=$cmd user=$user for sustained >50% CPU" >> $LOG
    fi
done
EOF
chmod +x /usr/local/bin/titan-watchdog.sh
echo "* * * * * root /usr/local/bin/titan-watchdog.sh" > /etc/cron.d/titan-watchdog

# Layer D: Shell policy — block python/mpirun on interactive shells
cat > /etc/profile.d/titan-login-policy.sh <<'EOF'
# Heavy-compute commands disabled on login node; submit via sbatch instead.
if [[ $- == *i* ]] && [[ -z "$TITAN_BATCH" ]]; then
    for cmd in python python3 mpirun mpiexec nvidia-smi; do
        alias $cmd='echo "[titan-hpc] $cmd is disabled on the login node. Submit a Slurm job: sbatch your-script.sh"; false'
    done
fi
EOF

# ----------------------------------------------------------------------------
# Helper: show cluster info on login
# ----------------------------------------------------------------------------
cat > /etc/motd <<EOF

======================================================================
  Titan HPC — Login Node
======================================================================

  Web UI:     https://<your-alb-hostname>/
  Head node:  ${head_node_ip} (internal only)
  FSx:        /fsx
  
  Submit a job:   sbatch myjob.sh
  Check queue:    squeue
  Cancel:         scancel <jobid>

  NOTE: heavy compute is disabled here. Jobs run on the GPU fleet.

EOF

echo "[$(date)] titan-hpc login node bootstrap complete"
