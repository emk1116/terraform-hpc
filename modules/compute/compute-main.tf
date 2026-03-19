resource "aws_key_pair" "hpc_key" {
  key_name   = "${var.namespace}-${var.env}-key"
  public_key = file(var.public_key_path)

  tags = {
    Name = "${var.namespace}-${var.env}-key"
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "head_node" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.hpc_key.key_name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install epel -y
    yum install -y munge munge-devel slurm slurm-slurmctld slurm-slurmd

    dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key

    systemctl enable munge
    systemctl start munge

    mkdir -p /etc/slurm /var/spool/slurm /var/log/slurm
    chown slurm:slurm /var/spool/slurm /var/log/slurm

    systemctl enable slurmctld
    systemctl start slurmctld
  EOF

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name = "${var.namespace}-${var.env}-head-node"
  }
}

resource "aws_eip" "head_node_eip" {
  instance = aws_instance.head_node.id
  domain   = "vpc"

  tags = {
    Name = "${var.namespace}-${var.env}-head-node-eip"
  }
}

resource "aws_instance" "compute_node" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  associate_public_ip_address = false
  key_name                    = aws_key_pair.hpc_key.key_name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install epel -y
    yum install -y munge munge-devel slurm slurm-slurmd

    dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key

    systemctl enable munge
    systemctl start munge

    mkdir -p /var/spool/slurmd /var/log/slurm
    chown slurm:slurm /var/spool/slurmd /var/log/slurm

    systemctl enable slurmd
    systemctl start slurmd
  EOF

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name = "${var.namespace}-${var.env}-compute-node"
  }
}
