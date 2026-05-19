# ============================================================================
# Titan HPC — workflow node
#
# Small EC2 instance dedicated to running Snakemake DAGs that submit jobs
# into Slurm. Kept separate from the login node so that long-running
# workflow daemons don't fight interactive shells for resources.
# (Nextflow / Cromwell can be added here later if the team needs them.)
#
# Cost: t3.small at $0.021/hr ≈ $15/month. Set enable_workflow_node=false in
# tfvars if you'd rather run Snakemake on the login node and save this cost.
# ============================================================================

variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "aws_region" { type = string }
variable "instance_type" { type = string }
variable "subnet_id" { type = string }
variable "security_group_ids" { type = list(string) }
variable "instance_profile_name" { type = string }
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

locals {
  user_data = <<-BASH
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/titan-workflow-bootstrap.log) 2>&1

    echo "[$(date)] titan-hpc workflow node bootstrap"

    # ---- packages ----
    dnf update -y
    dnf install -y python3 python3-pip jq awscli git nc

    # Snakemake + Slurm executor plugin
    pip3 install --upgrade pip
    pip3 install \
        snakemake==8.16.0 \
        snakemake-executor-plugin-slurm==0.11.2 \
        snakemake-storage-plugin-s3==0.2.12

    # ---- /etc/hosts: point "head" at the head node so slurm.conf resolves ----
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

    # ---- Munge (so the workflow node can sbatch into the cluster) ----
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
    # The head node builds Slurm from source on first boot then uploads
    # slurm-client-gpu.tar.gz to S3. That can take 8-15 minutes; retry.
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

    echo "[$(date)] workflow node ready. Test with:"
    echo "  sudo -u ec2-user sinfo"
    echo "  cd /fsx/shared/snakemake-demo && snakemake --profile slurm --jobs 5"
  BASH
}

resource "aws_instance" "workflow" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
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
    Name = "${var.name_prefix}-workflow"
    Role = "workflow"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

output "instance_id" { value = aws_instance.workflow.id }
output "private_ip" { value = aws_instance.workflow.private_ip }
