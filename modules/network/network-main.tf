resource "aws_vpc" "hpc_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true

  tags = {
    Name = "${var.namespace}-${var.env}-vpc"
  }
}

resource "aws_subnet" "hpc_subnet" {
  vpc_id            = aws_vpc.hpc_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "${var.namespace}-${var.env}-subnet"
  }
}

resource "aws_internet_gateway" "hpc_igw" {
  vpc_id = aws_vpc.hpc_vpc.id

  tags = {
    Name = "${var.namespace}-${var.env}-igw"
  }
}

resource "aws_route_table" "hpc_rt" {
  vpc_id = aws_vpc.hpc_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hpc_igw.id
  }

  tags = {
    Name = "${var.namespace}-${var.env}-rt"
  }
}

resource "aws_route_table_association" "hpc_rta" {
  subnet_id      = aws_subnet.hpc_subnet.id
  route_table_id = aws_route_table.hpc_rt.id
}

resource "aws_security_group" "hpc_sg" {
  vpc_id = aws_vpc.hpc_vpc.id

  tags = {
    Name = "${var.namespace}-${var.env}-sg"
  }

  # SSH access restricted to known CIDR
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # Allow all intra-cluster traffic (MPI, NFS, inter-node comms)
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Keep egress open — HPC needs package downloads, MPI, data transfers
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
