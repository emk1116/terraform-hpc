# ============================================================================
# Login node — the user's entry point to the HPC cluster.
#
# Provides SSH (public EIP) and SSM access. Has the Slurm client installed
# so users can run `sbatch`, `squeue`, `sacct` directly. FSx mounted at /fsx.
# Snakemake / Nextflow can run here for ad-hoc workflows.
# ============================================================================

variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "aws_region" { type = string }
variable "instance_type" { type = string }
variable "subnet_id" { type = string }
variable "security_group_ids" { type = list(string) }
variable "instance_profile_name" { type = string }
variable "ssh_public_key" { type = string }
variable "fsx_dns_name" { type = string }
variable "fsx_mount_name" { type = string }
variable "head_node_ip" { type = string }
variable "s3_bucket_name" { type = string }
variable "munge_key_parameter" { type = string }

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_key_pair" "login" {
  key_name_prefix = "${var.name_prefix}-"
  public_key      = var.ssh_public_key
}

resource "aws_eip" "login" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-login-eip" }
}

locals {
  user_data = <<-BASH
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/titan-login-bootstrap.log) 2>&1

    echo "[$(date)] titan-hpc login node bootstrap"

    # ---- packages ----
    dnf update -y
    dnf install -y jq awscli nc git python3 python3-pip

    # Snakemake + Slurm executor plugin (so users can run snakemake here too)
    pip3 install --upgrade pip
    pip3 install \
        snakemake==8.16.0 \
        snakemake-executor-plugin-slurm==0.11.2

    # ---- /etc/hosts: point "head" at the head node (slurm.conf uses it) ----
    echo "${var.head_node_ip} head" >> /etc/hosts

    # ---- Lustre client + FSx mount ----
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
    echo "${var.fsx_dns_name}@tcp:/${var.fsx_mount_name} /fsx lustre defaults,noatime,flock,_netdev 0 0" >> /etc/fstab
    for i in 1 2 3 4 5; do
        if mount -a && mountpoint -q /fsx; then break; fi
        sleep 10
    done

    # ---- Munge (so the login node can sbatch into the cluster) ----
    useradd -r -u 402 munge || true
    mkdir -p /etc/munge /var/log/munge /var/lib/munge /run/munge
    aws ssm get-parameter --region "${var.aws_region}" --name "${var.munge_key_parameter}" \
        --with-decryption --query 'Parameter.Value' --output text | \
        base64 -d > /etc/munge/munge.key
    chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge
    chmod 400 /etc/munge/munge.key
    dnf install -y munge
    systemctl enable --now munge

    # ---- Slurm client binaries — wait for head node to upload the tarball ----
    mkdir -p /opt/slurm
    for i in $(seq 1 60); do
        if aws s3 cp "s3://${var.s3_bucket_name}/platform/slurm-client-gpu.tar.gz" /tmp/slurm.tar.gz 2>/dev/null; then
            break
        fi
        echo "[$(date)] waiting for head node to upload slurm client (attempt $i/60)..."
        sleep 30
    done
    tar xzf /tmp/slurm.tar.gz -C /opt/slurm --strip-components=1 2>/dev/null || \
        tar xzf /tmp/slurm.tar.gz -C /opt/slurm
    echo 'export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH' > /etc/profile.d/slurm.sh

    # ---- Slurm config — retry until head node has uploaded slurm.conf ----
    mkdir -p /etc/slurm
    for i in $(seq 1 30); do
        if aws s3 cp "s3://${var.s3_bucket_name}/platform/slurm.conf" /etc/slurm/slurm.conf 2>/dev/null; then
            break
        fi
        sleep 15
    done
    aws s3 cp "s3://${var.s3_bucket_name}/platform/gres.conf" /etc/slurm/gres.conf 2>/dev/null || true

    # ---- Stage the Snakemake demo from S3 if the head node uploaded it ----
    mkdir -p /fsx/shared
    aws s3 sync "s3://${var.s3_bucket_name}/platform/examples/snakemake-demo/" \
        /fsx/shared/snakemake-demo/ 2>/dev/null || true

    echo "[$(date)] login node ready. Smoke test:"
    echo "  /opt/slurm/bin/sinfo"
    echo "  /opt/slurm/bin/sbatch jobs/inference_job.sh"
  BASH
}

resource "aws_instance" "login" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  key_name               = aws_key_pair.login.key_name
  iam_instance_profile   = var.instance_profile_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = local.user_data

  tags = {
    Name = "${var.name_prefix}-login"
    Role = "login"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "login" {
  instance_id   = aws_instance.login.id
  allocation_id = aws_eip.login.id
}

output "instance_id" { value = aws_instance.login.id }
output "public_ip" { value = aws_eip.login.public_ip }
