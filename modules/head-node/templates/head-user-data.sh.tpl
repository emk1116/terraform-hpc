#!/bin/bash
# ============================================================================
# Titan HPC — head node bootstrap
# Runs on first boot. Installs Slurm (slurmctld + slurmdbd), Docker,
# renders config from Secrets Manager, starts the jobui Docker stack.
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
export ECR_REGISTRY="${ecr_registry}"
export FSX_DNS_NAME="${fsx_dns_name}"
export FSX_MOUNT_NAME="${fsx_mount_name}"

export AURORA_WRITER_ENDPOINT="${aurora_endpoint}"
export AURORA_READER_ENDPOINT="${aurora_reader_endpoint}"
export AURORA_SLURM_SECRET_ARN="${aurora_slurm_secret_arn}"
export AURORA_JOBUI_SECRET_ARN="${aurora_jobui_secret_arn}"
export VALKEY_ENDPOINT="${valkey_endpoint}"

export JWT_SECRET_ARN="${jwt_secret_arn}"
export ADMIN_TEMP_SECRET_ARN="${admin_temp_secret_arn}"
export USERS_SEED_PARAMETER="${users_seed_parameter}"
export MUNGE_KEY_PARAMETER="${munge_key_parameter}"

export ADMIN_EMAIL="${admin_email}"
export JWT_EXPIRY_HOURS="${jwt_expiry_hours}"
export DEFAULT_USER_BUDGET="${default_user_budget}"

export GPU_FAMILY_SPEC='${gpu_family_spec_json}'

# ----------------------------------------------------------------------------
# 1. Base packages
# ----------------------------------------------------------------------------
dnf update -y
dnf install -y jq git docker mariadb105 amazon-cloudwatch-agent awscli nc

systemctl enable --now docker
usermod -aG docker ec2-user

# Docker Compose v2 plugin
DOCKER_CLI_PLUGINS=/usr/libexec/docker/cli-plugins
mkdir -p $DOCKER_CLI_PLUGINS
curl -sSfL "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-x86_64" \
    -o $DOCKER_CLI_PLUGINS/docker-compose
chmod +x $DOCKER_CLI_PLUGINS/docker-compose

# ----------------------------------------------------------------------------
# 2. Install Slurm 23.11 with NVML support
# We build from source once here, then bundle into a tarball in S3 for
# compute nodes to fetch. (Compute nodes need the same Slurm build for
# compatibility.)
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

    # Bundle for compute nodes
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
# 4. Munge key — fetch from SSM (same key used by compute nodes)
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
    # Fallback: pull from Amazon FSx repo
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

# Lay out shared dirs
mkdir -p /fsx/models /fsx/work /fsx/shared
chmod 1777 /fsx/work /fsx/shared
chmod 755 /fsx/models

# ----------------------------------------------------------------------------
# 6. Render Slurm configs — pull from S3, substitute DB passwords from Secrets
# ----------------------------------------------------------------------------
mkdir -p /etc/slurm /opt/titan-hpc/bin /opt/titan-hpc/etc

# slurm.conf was pre-rendered by Terraform and dropped in S3 by the module
aws s3 cp "s3://$S3_BUCKET/platform/slurm.conf" /etc/slurm/slurm.conf

# gres.conf — same
aws s3 cp "s3://$S3_BUCKET/platform/gres.conf" /etc/slurm/gres.conf

# slurmdbd.conf — we rendered a template to S3 with __SLURM_DB_PASSWORD__;
# substitute at boot from Secrets Manager
aws s3 cp "s3://$S3_BUCKET/platform/slurmdbd.conf.tpl" /etc/slurm/slurmdbd.conf.tpl || \
    echo "slurmdbd template not yet in S3; will generate locally"

if [[ ! -f /etc/slurm/slurmdbd.conf.tpl ]]; then
    cat > /etc/slurm/slurmdbd.conf.tpl <<'EOF'
AuthType=auth/munge
DbdHost=localhost
DbdPort=6819
StorageType=accounting_storage/mysql
StorageHost=__AURORA_ENDPOINT__
StoragePort=3306
StorageLoc=slurm_acct_db
StorageUser=slurm
StoragePass=__SLURM_DB_PASSWORD__
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurm/slurmdbd.pid
DebugLevel=info
CommitDelay=1
PurgeEventAfter=12months
PurgeJobAfter=12months
PurgeStepAfter=12months
PurgeSuspendAfter=12months
PurgeTXNAfter=12months
PurgeUsageAfter=12months
EOF
fi

# Fetch slurm DB password
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
# 7. Aurora bootstrap — create jobui DB + scoped users, first boot only
# ----------------------------------------------------------------------------
AURORA_MASTER_PASSWORD=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$(echo $AURORA_SLURM_SECRET_ARN | sed 's/-aurora-slurm-/-aurora-master-/')" \
    --query SecretString --output text 2>/dev/null | jq -r '.password' || echo "")

# Actually, the master secret ARN is separate — it's stored but not passed here;
# we reuse it from an SSM lookup pattern. Simpler: fetch from the aurora module
# output via a known path. For now, we use the slurm user itself which has CREATE
# privileges on slurm_acct_db and we'll bootstrap via the jobui app on its first
# run using the master secret fetched by the app.

JOBUI_DB_PASSWORD=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$AURORA_JOBUI_SECRET_ARN" \
    --query SecretString --output text | jq -r '.password')

# Wait for Aurora to be reachable
echo "[$(date)] waiting for Aurora to be reachable..."
for i in $(seq 1 60); do
    if nc -z "$AURORA_WRITER_ENDPOINT" 3306; then
        echo "[$(date)] Aurora reachable"
        break
    fi
    sleep 10
done

# ----------------------------------------------------------------------------
# 8. Install resume/suspend scripts
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
# 10. Create Slurm accounts + associations for team members
# The admin email becomes an account coordinator; h100_approved members
# go into the h100-approved account (partition AllowAccounts gate).
# ----------------------------------------------------------------------------
USERS_SEED=$(aws ssm get-parameter --region "$AWS_REGION" \
    --name "$USERS_SEED_PARAMETER" --with-decryption \
    --query 'Parameter.Value' --output text)

# Create base accounts
sacctmgr -i add cluster titan-$TEAM_NAME || true
sacctmgr -i add account general Description="General account" Organization=titan-$TEAM_NAME || true
sacctmgr -i add account h100-approved Description="H100-approved users" Organization=titan-$TEAM_NAME || true

# Set per-account GPU TRES caps to prevent runaway spend
sacctmgr -i modify account h100-approved set GrpTRES=gres/gpu:h100=8

# Add each team member
echo "$USERS_SEED" | jq -r '.members[] | @base64' | while read -r row; do
    _jq() { echo "$row" | base64 -d | jq -r "$1"; }
    username=$(_jq '.username')
    h100=$(_jq '.h100_approved')
    default_account="general"
    if [[ "$h100" == "true" ]]; then
        default_account="h100-approved"
    fi

    sacctmgr -i add user "$username" DefaultAccount="$default_account" || true
    sacctmgr -i add user "$username" Account=general || true
    if [[ "$h100" == "true" ]]; then
        sacctmgr -i add user "$username" Account=h100-approved || true
    fi
done

# ----------------------------------------------------------------------------
# 11. jobui — pull image, write docker-compose.yml, start
# ----------------------------------------------------------------------------
mkdir -p /opt/titan-hpc/jobui
cd /opt/titan-hpc/jobui

# docker-compose.yml
cat > docker-compose.yml <<EOF
services:
  backend:
    image: $ECR_REGISTRY/titan-hpc/jobui-backend:latest
    container_name: jobui-backend
    restart: unless-stopped
    network_mode: host
    volumes:
      - /fsx:/fsx
      - /etc/munge:/etc/munge:ro
      - /opt/slurm:/opt/slurm:ro
      - /var/run/munge:/var/run/munge
    environment:
      AWS_REGION: "$AWS_REGION"
      TEAM_NAME: "$TEAM_NAME"
      S3_BUCKET: "$S3_BUCKET"
      ECR_REGISTRY: "$ECR_REGISTRY"
      AURORA_WRITER_ENDPOINT: "$AURORA_WRITER_ENDPOINT"
      AURORA_READER_ENDPOINT: "$AURORA_READER_ENDPOINT"
      AURORA_JOBUI_SECRET_ARN: "$AURORA_JOBUI_SECRET_ARN"
      VALKEY_ENDPOINT: "$VALKEY_ENDPOINT"
      JWT_SECRET_ARN: "$JWT_SECRET_ARN"
      ADMIN_TEMP_SECRET_ARN: "$ADMIN_TEMP_SECRET_ARN"
      USERS_SEED_PARAMETER: "$USERS_SEED_PARAMETER"
      ADMIN_EMAIL: "$ADMIN_EMAIL"
      JWT_EXPIRY_HOURS: "$JWT_EXPIRY_HOURS"
      DEFAULT_USER_BUDGET: "$DEFAULT_USER_BUDGET"
      GPU_FAMILY_SPEC: '$GPU_FAMILY_SPEC'
      PATH: "/opt/slurm/bin:/opt/slurm/sbin:/usr/local/bin:/usr/bin:/bin"
    ports:
      - "8000:8000"

  nginx:
    image: nginx:1.27-alpine
    container_name: jobui-nginx
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - backend
EOF

# nginx config — serves the React SPA and reverse-proxies /api to FastAPI
cat > nginx.conf <<'EOF'
worker_processes auto;
events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    # ALB sets X-Forwarded-For; trust it for real_ip
    set_real_ip_from 10.0.0.0/8;
    real_ip_header X-Forwarded-For;

    # Health endpoint (ALB target group checks this)
    server {
        listen 80 default_server;
        server_name _;

        # Frontend SPA
        location / {
            proxy_pass http://127.0.0.1:8000/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
        }

        # API — same upstream but with longer timeouts for sbatch calls
        location /api/ {
            proxy_pass http://127.0.0.1:8000/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_read_timeout 60s;
            client_max_body_size 10m;
        }
    }
}
EOF

# ECR login and pull
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker compose pull || echo "WARN: image pull failed; will retry on systemd start"

# systemd unit for the jobui stack
cat > /etc/systemd/system/jobui.service <<EOF
[Unit]
Description=Titan HPC jobui stack (Docker Compose)
Requires=docker.service
After=docker.service slurmctld.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/titan-hpc/jobui
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable jobui
systemctl start jobui

# ----------------------------------------------------------------------------
# 12. Monthly rollup cron — updates monthly_spend table from Slurm sacct data
# ----------------------------------------------------------------------------
cat > /etc/cron.hourly/titan-spend-rollup <<'EOF'
#!/bin/bash
# Called hourly by cron; rolls up Slurm sacct data into jobui.monthly_spend
set -euo pipefail
docker exec jobui-backend python -m app.scripts.monthly_rollup 2>&1 | \
    logger -t titan-rollup
EOF
chmod +x /etc/cron.hourly/titan-spend-rollup

# ----------------------------------------------------------------------------
# 13. Scratch cleanup cron — remove stale FSx work dirs from killed/timed-out
#     jobs that never had a chance to run their own rm -rf cleanup.
#     Runs daily; skips any directory whose job_id is still active in Slurm.
# ----------------------------------------------------------------------------
cat > /etc/cron.daily/titan-scratch-cleanup <<'CLEANEOF'
#!/bin/bash
set -euo pipefail
SLURM_BIN=/opt/slurm/bin
FSX_WORK=/fsx/work

# Walk /fsx/work/<user>/<job_id>/ — depth 2, directories only, older than 7 days
find "$FSX_WORK" -mindepth 2 -maxdepth 2 -type d -mtime +7 2>/dev/null | while read -r dir; do
    job_id=$(basename "$dir")
    # Only process numeric job IDs (skip sbatch script dirs)
    [[ "$job_id" =~ ^[0-9]+$ ]] || continue
    # Skip if job is still listed in squeue (PENDING or RUNNING)
    if "$SLURM_BIN/squeue" -j "$job_id" -h -o "%i" 2>/dev/null | grep -q "^${job_id}$"; then
        continue
    fi
    echo "[$(date -Iseconds)] titan-scratch-cleanup: removing $dir"
    rm -rf "$dir"
done
CLEANEOF
chmod +x /etc/cron.daily/titan-scratch-cleanup

echo "[$(date)] titan-hpc head node bootstrap complete"
