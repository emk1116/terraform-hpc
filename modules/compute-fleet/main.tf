variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "active_gpus" {
  description = "Map of gpu_family → spec. See root main.tf local.gpu_family_spec for shape."
  type        = any
}
variable "instance_profile_name" { type = string }
variable "security_group_ids" { type = list(string) }
variable "subnet_id" { type = string }
variable "fsx_dns_name" { type = string }
variable "fsx_mount_name" { type = string }
variable "head_node_ip" { type = string }
variable "ecr_registry_url" { type = string }
variable "s3_bucket_name" { type = string }

# ----------------------------------------------------------------------------
# AMI — AWS Deep Learning AMI GPU (Amazon Linux 2023) — NVIDIA drivers,
# Docker, NVIDIA Container Toolkit, CUDA all preinstalled.
# ----------------------------------------------------------------------------

data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning AMI GPU PyTorch * (Amazon Linux 2023) *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ----------------------------------------------------------------------------
# User data template — bootstraps each GPU node on first boot.
# Installs Slurm client, FSx Lustre client, s5cmd; mounts FSx; joins cluster.
# ----------------------------------------------------------------------------

locals {
  user_data_template = <<-BASH
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/titan-bootstrap.log) 2>&1

    echo "[$(date)] titan-hpc compute node bootstrap starting"

    # ------------------------------------------------------------------------
    # 1. Hostname — match the Slurm node name passed via tag
    # ------------------------------------------------------------------------
    TOKEN=$(curl -sSf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    INSTANCE_ID=$(curl -sSf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    REGION=$(curl -sSf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

    NODE_NAME=$(aws ec2 describe-tags --region $REGION \
      --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=slurm-node" \
      --query 'Tags[0].Value' --output text)

    if [[ "$NODE_NAME" == "None" || -z "$NODE_NAME" ]]; then
      echo "[$(date)] ERROR: slurm-node tag not found, cannot register"
      exit 1
    fi

    hostnamectl set-hostname "$NODE_NAME"
    echo "$NODE_NAME" > /etc/hostname

    # ------------------------------------------------------------------------
    # 2. Install s5cmd (fast S3 transfers) and FSx Lustre client
    # ------------------------------------------------------------------------
    # s5cmd
    curl -sSfLo /tmp/s5cmd.tar.gz "https://github.com/peak/s5cmd/releases/download/v2.2.2/s5cmd_2.2.2_Linux-64bit.tar.gz"
    tar xzf /tmp/s5cmd.tar.gz -C /usr/local/bin/ s5cmd
    chmod +x /usr/local/bin/s5cmd

    # Lustre client — DLAMI might have it; if not, install from Amazon repos
    if ! command -v lctl >/dev/null 2>&1; then
      dnf install -y lustre-client || {
        echo "WARN: lustre-client package install failed, trying Amazon FSx repo"
        curl -sSfLo /tmp/fsx-lustre-client-repo.rpm https://fsx-lustre-client-repo-public-keys.s3.amazonaws.com/fsx-rpm-public-key.asc
        rpm --import /tmp/fsx-lustre-client-repo.rpm
        dnf install -y lustre-client
      }
    fi

    # ------------------------------------------------------------------------
    # 3. Mount FSx
    # ------------------------------------------------------------------------
    mkdir -p /fsx
    if ! grep -q "/fsx" /etc/fstab; then
      echo "${var.fsx_dns_name}@tcp:/${var.fsx_mount_name} /fsx lustre defaults,noatime,flock,_netdev 0 0" >> /etc/fstab
    fi

    # Retry mount — FSx may take a moment to be ready on fresh VPC
    for i in 1 2 3 4 5; do
      if mount -a && mountpoint -q /fsx; then
        echo "[$(date)] FSx mounted"
        break
      fi
      echo "[$(date)] FSx mount attempt $i failed, retrying..."
      sleep 10
    done

    # ------------------------------------------------------------------------
    # 4. Set up instance store NVMe for Docker (on P4/P5 instances)
    # ------------------------------------------------------------------------
    NVME_DEVICES=$(lsblk -d -n -o NAME,MODEL | awk '$2 ~ /Instance Storage/ {print "/dev/"$1}')
    if [[ -n "$NVME_DEVICES" ]]; then
      echo "[$(date)] instance store NVMe detected: $NVME_DEVICES"
      FIRST=$(echo "$NVME_DEVICES" | head -1)

      # Stop Docker, wipe, mount at /var/lib/docker, restart
      systemctl stop docker || true
      mkfs.xfs -f "$FIRST"
      mkdir -p /var/lib/docker
      mount "$FIRST" /var/lib/docker
      echo "$FIRST /var/lib/docker xfs defaults,noatime 0 0" >> /etc/fstab

      systemctl start docker
    fi

    # ------------------------------------------------------------------------
    # 5. Install Slurm client (compiled with NVML for GPU auto-detect)
    # We pull a pre-built tarball from S3 that the head node maintains,
    # or fall back to building from source.
    # ------------------------------------------------------------------------
    SLURM_TARBALL="s3://${var.s3_bucket_name}/platform/slurm-client-gpu.tar.gz"
    if aws s3 ls "$SLURM_TARBALL" >/dev/null 2>&1; then
      mkdir -p /opt/slurm
      aws s3 cp "$SLURM_TARBALL" /tmp/slurm.tar.gz
      tar xzf /tmp/slurm.tar.gz -C /opt/slurm --strip-components=1
    else
      echo "[$(date)] WARN: pre-built Slurm not found in S3; falling back to dnf"
      dnf install -y slurm-slurmd slurm-pam_slurm || {
        echo "[$(date)] ERROR: slurm install failed"
        exit 1
      }
    fi

    # ------------------------------------------------------------------------
    # 6. Fetch Munge key from SSM Parameter Store (set by head node)
    # ------------------------------------------------------------------------
    MUNGE_KEY=$(aws ssm get-parameter --region $REGION \
      --name "/titan-hpc/${var.team_name}/munge-key" \
      --with-decryption --query 'Parameter.Value' --output text)

    useradd -r -s /sbin/nologin munge || true
    mkdir -p /etc/munge /var/log/munge /var/lib/munge /run/munge
    echo "$MUNGE_KEY" | base64 -d > /etc/munge/munge.key
    chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge
    chmod 400 /etc/munge/munge.key
    chmod 755 /run/munge
    systemctl enable --now munge

    # ------------------------------------------------------------------------
    # 7. Write slurm.conf (fetched from head node's S3 drop)
    # ------------------------------------------------------------------------
    mkdir -p /etc/slurm
    aws s3 cp "s3://${var.s3_bucket_name}/platform/slurm.conf" /etc/slurm/slurm.conf
    aws s3 cp "s3://${var.s3_bucket_name}/platform/gres.conf" /etc/slurm/gres.conf

    useradd -r -u 401 slurm || true
    mkdir -p /var/spool/slurmd /var/log/slurm
    chown -R slurm:slurm /var/spool/slurmd /var/log/slurm

    # Start slurmd — the node name comes from hostname, which we set above
    systemctl enable --now slurmd

    echo "[$(date)] titan-hpc compute node bootstrap complete"
  BASH
}

# ----------------------------------------------------------------------------
# Launch template per GPU family
# ----------------------------------------------------------------------------

resource "aws_launch_template" "per_gpu" {
  for_each = var.active_gpus

  name_prefix            = "${var.name_prefix}-compute-${each.key}-"
  image_id               = data.aws_ami.dlami.id
  instance_type          = each.value.instance_type
  vpc_security_group_ids = var.security_group_ids

  iam_instance_profile {
    name = var.instance_profile_name
  }

  # IMDSv2 required
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.ebs_size_gb
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(local.user_data_template)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "${var.name_prefix}-compute-${each.key}"
      Team       = var.team_name
      GpuFamily  = each.key
      Role       = "compute"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.name_prefix}-compute-${each.key}-volume"
      Team = var.team_name
    }
  }

  tags = {
    Name      = "${var.name_prefix}-compute-${each.key}-lt"
    GpuFamily = each.key
  }
}

# ----------------------------------------------------------------------------
# Outputs — consumed by head-node module to generate resume-node.sh
# ----------------------------------------------------------------------------

output "ami_id" { value = data.aws_ami.dlami.id }

output "launch_template_ids" {
  description = "Map of gpu_family → launch template ID"
  value       = { for f, lt in aws_launch_template.per_gpu : f => lt.id }
}

output "launch_template_names" {
  description = "Map of gpu_family → launch template name (used by resume-node.sh)"
  value       = { for f, lt in aws_launch_template.per_gpu : f => lt.name }
}

output "launch_template_versions" {
  value = { for f, lt in aws_launch_template.per_gpu : f => lt.latest_version }
}
