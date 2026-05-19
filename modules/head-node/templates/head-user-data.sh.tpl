#!/bin/bash
# ============================================================================
# Titan HPC — head node bootstrap
# Installs Slurm (slurmctld + slurmdbd), publishes the Slurm client tarball
# to S3, and starts the controller. No web stack — pure HPC control plane.
# ============================================================================
set -euo pipefail
exec > >(tee /var/log/titan-head-bootstrap.log) 2>&1

echo "[$(date)] titan-hpc head node bootstrap starting"

# ----------------------------------------------------------------------------
# Exported config (injected by Terraform)
# ----------------------------------------------------------------------------
export TEAM_NAME="${team_name}"
export ENV="${env}"
export AWS_REGION="${aws_region}"
export S3_BUCKET="${s3_bucket}"
export FSX_DNS_NAME="${fsx_dns_name}"
export FSX_MOUNT_NAME="${fsx_mount_name}"

export AURORA_WRITER_ENDPOINT="${aurora_endpoint}"
export AURORA_SLURM_SECRET_ARN="${aurora_slurm_secret_arn}"
export MUNGE_KEY_PARAMETER="${munge_key_parameter}"

# ----------------------------------------------------------------------------
# 1. Base packages
# ----------------------------------------------------------------------------
dnf update -y
dnf install -y jq git mariadb105 awscli nc

# ----------------------------------------------------------------------------
# 2. Install Slurm 23.11 with NVML support
# Build from source once here, then bundle into a tarball in S3 for login,
# workflow, and compute nodes to fetch.
# ----------------------------------------------------------------------------
SLURM_VERSION=23.11.10
SLURM_TARBALL_KEY="platform/slurm-$SLURM_VERSION.tar.gz"

if ! aws s3 ls "s3://$S3_BUCKET/$SLURM_TARBALL_KEY" >/dev/null 2>&1; then
    echo "[$(date)] building Slurm $SLURM_VERSION from source"
    dnf install -y gcc make munge munge-devel mariadb105-server-devel \
        openssl-devel pam-devel readline-devel hwloc-devel \
        perl-ExtUtils-MakeMaker python3 rpm-build

    cd /tmp
    curl -sSfLo slurm.tar.bz2 "https://download.schedmd.com/slurm/slurm-$SLURM_VERSION.tar.bz2"
    tar xjf slurm.tar.bz2
    cd slurm-$SLURM_VERSION

    ./configure --prefix=/opt/slurm --sysconfdir=/etc/slurm --enable-pam
    make -j"$(nproc)"
    make install

    tar czf /tmp/slurm-bundle.tar.gz -C /opt/slurm .
    aws s3 cp /tmp/slurm-bundle.tar.gz "s3://$S3_BUCKET/$SLURM_TARBALL_KEY"
    aws s3 cp /tmp/slurm-bundle.tar.gz "s3://$S3_BUCKET/platform/slurm-client-gpu.tar.gz"
else
    echo "[$(date)] using pre-built Slurm from S3"
    mkdir -p /opt/slurm
    aws s3 cp "s3://$S3_BUCKET/$SLURM_TARBALL_KEY" /tmp/slurm.tar.gz
    tar xzf /tmp/slurm.tar.gz -C /opt/slurm
    dnf install -y munge
fi

echo 'export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH' > /etc/profile.d/slurm.sh
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH

# ----------------------------------------------------------------------------
# 3. Users for slurm + munge
# ----------------------------------------------------------------------------
useradd -r -u 401 slurm || true
useradd -r -u 402 munge || true

mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd /var/run/slurm
chown -R slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd /var/run/slurm

# ----------------------------------------------------------------------------
# 4. Munge key — fetch from SSM (same key shared with all cluster nodes)
# ----------------------------------------------------------------------------
mkdir -p /etc/munge /var/log/munge /var/lib/munge /run/munge
MUNGE_KEY_B64=$(aws ssm get-parameter --region "$AWS_REGION" \
    --name "$MUNGE_KEY_PARAMETER" --with-decryption \
    --query 'Parameter.Value' --output text)
echo "$MUNGE_KEY_B64" | base64 -d > /etc/munge/munge.key
chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge
chmod 400 /etc/munge/munge.key
chmod 755 /run/munge
systemctl enable --now munge

# ----------------------------------------------------------------------------
# 5. FSx mount
# ----------------------------------------------------------------------------
dnf install -y lustre-client || {
    curl -sSfLo /etc/pki/rpm-gpg/RPM-GPG-KEY-fsx \
        https://fsx-lustre-client-repo-public-keys.s3.amazonaws.com/fsx-rpm-public-key.asc
    cat > /etc/yum.repos.d/aws-fsx.repo <<EOF
[aws-fsx]
name=Amazon FSx Lustre Client Repository
baseurl=https://fsx-lustre-client-repo.s3.amazonaws.com/al2023/latest/x86_64
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fsx
EOF
    dnf install -y lustre-client
}

mkdir -p /fsx
echo "$FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME /fsx lustre defaults,noatime,flock,_netdev 0 0" >> /etc/fstab

for i in 1 2 3 4 5; do
    if mount -a && mountpoint -q /fsx; then
        echo "[$(date)] FSx mounted"
        break
    fi
    echo "[$(date)] FSx mount attempt $i failed, retrying..."
    sleep 15
done

mkdir -p /fsx/models /fsx/work /fsx/shared
chmod 1777 /fsx/work /fsx/shared
chmod 755 /fsx/models

# Stage Snakemake demo from S3 to FSx for the workflow / login nodes (best-effort)
aws s3 sync "s3://$S3_BUCKET/platform/examples/snakemake-demo/" \
    /fsx/shared/snakemake-demo/ 2>/dev/null || \
    echo "snakemake-demo not in S3 yet — upload it after deploy."
chmod -R a+rwX /fsx/shared/snakemake-demo 2>/dev/null || true

# ----------------------------------------------------------------------------
# 6. Render Slurm configs — pull from S3, substitute DB password from Secrets
# ----------------------------------------------------------------------------
mkdir -p /etc/slurm /opt/titan-hpc/bin

aws s3 cp "s3://$S3_BUCKET/platform/slurm.conf" /etc/slurm/slurm.conf
aws s3 cp "s3://$S3_BUCKET/platform/gres.conf" /etc/slurm/gres.conf
aws s3 cp "s3://$S3_BUCKET/platform/slurmdbd.conf.tpl" /etc/slurm/slurmdbd.conf.tpl

SLURM_DB_PASSWORD=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$AURORA_SLURM_SECRET_ARN" \
    --query SecretString --output text | jq -r '.password')

sed -e "s|__AURORA_ENDPOINT__|$AURORA_WRITER_ENDPOINT|g" \
    -e "s|__SLURM_DB_PASSWORD__|$SLURM_DB_PASSWORD|g" \
    /etc/slurm/slurmdbd.conf.tpl > /etc/slurm/slurmdbd.conf

chown slurm:slurm /etc/slurm/slurmdbd.conf
chmod 600 /etc/slurm/slurmdbd.conf

# ----------------------------------------------------------------------------
# 7. Wait for Aurora to be reachable
# ----------------------------------------------------------------------------
echo "[$(date)] waiting for Aurora to be reachable..."
for i in $(seq 1 60); do
    if nc -z "$AURORA_WRITER_ENDPOINT" 3306; then
        echo "[$(date)] Aurora reachable"
        break
    fi
    sleep 10
done

# ----------------------------------------------------------------------------
# 8. Install Resume/Suspend scripts
# ----------------------------------------------------------------------------
aws s3 cp "s3://$S3_BUCKET/platform/resume-node.sh" /opt/titan-hpc/bin/resume-node.sh
aws s3 cp "s3://$S3_BUCKET/platform/suspend-node.sh" /opt/titan-hpc/bin/suspend-node.sh
chmod +x /opt/titan-hpc/bin/resume-node.sh /opt/titan-hpc/bin/suspend-node.sh
chown slurm:slurm /opt/titan-hpc/bin/resume-node.sh /opt/titan-hpc/bin/suspend-node.sh

# ----------------------------------------------------------------------------
# 9. systemd units for slurmctld and slurmdbd
# ----------------------------------------------------------------------------
cat > /etc/systemd/system/slurmdbd.service <<EOF
[Unit]
Description=Slurm DBD accounting daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=simple
ExecStart=/opt/slurm/sbin/slurmdbd -D
User=slurm
Group=slurm
LimitNOFILE=65536
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/slurmctld.service <<EOF
[Unit]
Description=Slurm controller daemon
After=network.target munge.service slurmdbd.service
Requires=munge.service

[Service]
Type=simple
ExecStart=/opt/slurm/sbin/slurmctld -D
User=slurm
Group=slurm
LimitNOFILE=65536
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slurmdbd slurmctld
systemctl start slurmdbd
sleep 5
systemctl start slurmctld

# ----------------------------------------------------------------------------
# 10. Create base Slurm accounts (general + h100-approved).
#     Per-user associations are added later via sacctmgr by an admin, or
#     created on demand when a user first runs sbatch under that account.
# ----------------------------------------------------------------------------
sacctmgr -i add cluster "titan-$TEAM_NAME" || true
sacctmgr -i add account general Description="General GPU work" Organization="titan-$TEAM_NAME" || true
sacctmgr -i add account h100-approved Description="H100-eligible users" Organization="titan-$TEAM_NAME" || true

# ----------------------------------------------------------------------------
# 11. Daily scratch cleanup cron — removes FSx work dirs from killed jobs
# ----------------------------------------------------------------------------
cat > /etc/cron.daily/titan-scratch-cleanup <<'CLEANEOF'
#!/bin/bash
set -euo pipefail
SLURM_BIN=/opt/slurm/bin
FSX_WORK=/fsx/work

find "$FSX_WORK" -mindepth 2 -maxdepth 2 -type d -mtime +7 2>/dev/null | while read -r dir; do
    job_id=$(basename "$dir")
    [[ "$job_id" =~ ^[0-9]+$ ]] || continue
    if "$SLURM_BIN/squeue" -j "$job_id" -h -o "%i" 2>/dev/null | grep -q "^$${job_id}$$"; then
        continue
    fi
    echo "[$(date -Iseconds)] titan-scratch-cleanup: removing $dir"
    rm -rf "$dir"
done
CLEANEOF
chmod +x /etc/cron.daily/titan-scratch-cleanup

echo "[$(date)] titan-hpc head node bootstrap complete"
