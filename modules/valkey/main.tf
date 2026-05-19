variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "allowed_sg_ids" { type = list(string) }

# ----------------------------------------------------------------------------
# Security group
# ----------------------------------------------------------------------------

resource "aws_security_group" "valkey" {
  name_prefix = "${var.name_prefix}-valkey-"
  description = "Valkey Serverless — reachable from head node only"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = toset(var.allowed_sg_ids)
    content {
      description     = "Valkey TLS from allowed SG"
      from_port       = 6379
      to_port         = 6379
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-valkey-sg" }
}

# ----------------------------------------------------------------------------
# Valkey Serverless cache
# Naming constraint: ElastiCache Serverless cache names must be ≤40 chars
# ----------------------------------------------------------------------------

resource "aws_elasticache_serverless_cache" "valkey" {
  engine = "valkey"
  name   = "${var.name_prefix}-cache"

  cache_usage_limits {
    data_storage {
      maximum = 2 # GB
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 5000
    }
  }

  daily_snapshot_time      = "03:00"
  snapshot_retention_limit = 1

  security_group_ids = [aws_security_group.valkey.id]
  subnet_ids         = var.subnet_ids

  description = "Cache for jobui — sessions, rate limits, queue status"

  tags = { Name = "${var.name_prefix}-valkey" }
}

output "endpoint" {
  value = aws_elasticache_serverless_cache.valkey.endpoint[0].address
}

output "port" {
  value = aws_elasticache_serverless_cache.valkey.endpoint[0].port
}

output "security_group_id" {
  value = aws_security_group.valkey.id
}
