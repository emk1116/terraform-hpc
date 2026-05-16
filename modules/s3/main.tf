variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "force_destroy" { type = bool }

resource "random_id" "bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "data" {
  bucket        = "${var.name_prefix}-data-${random_id.bucket.hex}"
  force_destroy = var.force_destroy

  tags = {
    Name    = "${var.name_prefix}-data"
    Purpose = "hpc-inputs-and-results"
  }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS for browser-initiated multipart uploads
resource "aws_s3_bucket_cors_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  cors_rule {
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = ["*"]  # TODO: tighten to ALB hostname in prod
    allowed_headers = ["*"]
    expose_headers  = ["ETag", "x-amz-server-side-encryption"]
    max_age_seconds = 3000
  }
}

# Lifecycle: abort stalled multipart uploads, expire old versions, archive old results
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }
  }

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "archive-old-results"
    status = "Enabled"

    filter {
      prefix = "results/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

output "bucket_name" { value = aws_s3_bucket.data.bucket }
output "bucket_arn" { value = aws_s3_bucket.data.arn }
