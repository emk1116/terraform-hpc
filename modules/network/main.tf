variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "primary_az" { type = string }
variable "aws_region" { type = string }
variable "h100_fallback_azs" { type = list(string) }
variable "ssh_allowed_cidr" { type = string }

# All AZs we might ever land a compute node in
locals {
  all_azs = distinct(concat([var.primary_az], var.h100_fallback_azs))
}

# ----------------------------------------------------------------------------
# VPC
# ----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# ----------------------------------------------------------------------------
# Public subnets — one per AZ we might use (for login node, NAT GW)
# ----------------------------------------------------------------------------

locals {
  public_subnet_azs = [var.primary_az]
}

resource "aws_subnet" "public" {
  for_each = { for i, az in local.public_subnet_azs : az => i }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value)
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ----------------------------------------------------------------------------
# NAT Gateway — one, in the primary AZ's public subnet
# ----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.primary_az].id

  tags = { Name = "${var.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.main]
}

# ----------------------------------------------------------------------------
# Private subnets — one per AZ we might use (head node, Aurora, Valkey, compute)
# ----------------------------------------------------------------------------

resource "aws_subnet" "private" {
  for_each = { for i, az in local.all_azs : az => i + 10 }

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value)
  availability_zone = each.key

  tags = {
    Name = "${var.name_prefix}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ----------------------------------------------------------------------------
# VPC endpoints — keep S3/ECR/SSM/Secrets traffic on AWS backbone
# ----------------------------------------------------------------------------

# Gateway endpoint for S3 (free)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name_prefix}-s3-endpoint" }
}

# Interface endpoints — charged per-hour but much better for security + perf
resource "aws_security_group" "vpce" {
  name_prefix = "${var.name_prefix}-vpce-"
  description = "Allow HTTPS from VPC to interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-vpce-sg" }
}

locals {
  interface_endpoints = [
    "ec2", # run-instances, terminate-instances for ResumeProgram
    "ecr.api",
    "ecr.dkr",
    "ssm",
    "ssmmessages",
    "ec2messages", # SSM Session Manager
    "secretsmanager",
    "logs",
    # elasticache Serverless has no VPC interface endpoint; it uses standard VPC routing
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[var.primary_az].id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-${each.key}-endpoint" }
}

# ----------------------------------------------------------------------------
# Security Groups — one per tier, with explicit ingress rules
# ----------------------------------------------------------------------------

# Login node SG — SSH from allowed CIDR only
resource "aws_security_group" "login_node" {
  name_prefix = "${var.name_prefix}-login-"
  description = "Login node — SSH entry point"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-login-sg" }
}

# Head node SG — Slurm controller. No web ports. SSM-only admin access.
resource "aws_security_group" "head_node" {
  name_prefix = "${var.name_prefix}-head-"
  description = "Head node — slurmctld + slurmdbd"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from login node (admin convenience)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.login_node.id]
  }

  ingress {
    description = "Slurm controller ports (slurmctld, slurmdbd) within VPC"
    from_port   = 6817
    to_port     = 6819
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-head-sg" }
}

# Compute SG — egress all, ingress Slurm from head
resource "aws_security_group" "compute" {
  name_prefix = "${var.name_prefix}-compute-"
  description = "GPU compute nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Slurm from head node"
    from_port       = 6817
    to_port         = 6819
    protocol        = "tcp"
    security_groups = [aws_security_group.head_node.id]
  }

  ingress {
    description = "MPI / ephemeral between compute nodes (same SG)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-compute-sg" }
}

# FSx Lustre SG — allow Lustre traffic from head + compute + login
resource "aws_security_group" "fsx" {
  name_prefix = "${var.name_prefix}-fsx-"
  description = "FSx Lustre filesystem"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Lustre from VPC"
    from_port   = 988
    to_port     = 988
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Lustre ephemeral ports"
    from_port   = 1018
    to_port     = 1023
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-fsx-sg" }
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------

output "vpc_id" { value = aws_vpc.main.id }
output "vpc_cidr" { value = aws_vpc.main.cidr_block }

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  value = [for az in local.all_azs : aws_subnet.private[az].id]
}

output "compute_subnet_ids_by_az" {
  description = "Map of AZ → private subnet ID, used by ResumeProgram for multi-AZ H100 fallback"
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "login_node_sg_id" { value = aws_security_group.login_node.id }
output "head_node_sg_id" { value = aws_security_group.head_node.id }
output "compute_sg_id" { value = aws_security_group.compute.id }
output "fsx_sg_id" { value = aws_security_group.fsx.id }
