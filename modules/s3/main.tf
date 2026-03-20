resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "hpc_data" {
  bucket        = "${var.namespace}-${var.env}-hpc-data-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "${var.namespace}-${var.env}-hpc-data"
    Namespace   = var.namespace
    Environment = var.env
    Project     = "hpc"
  }
}

resource "aws_s3_bucket_versioning" "hpc_data" {
  bucket = aws_s3_bucket.hpc_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "hpc_data" {
  bucket = aws_s3_bucket.hpc_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "hpc_data" {
  bucket                  = aws_s3_bucket.hpc_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Seed the input/ prefix so it exists in the console
resource "aws_s3_object" "input_prefix" {
  bucket  = aws_s3_bucket.hpc_data.id
  key     = "input/.keep"
  content = "# Upload input files here. Jobs will download from s3://<bucket>/input/\n"

  tags = { Purpose = "prefix-placeholder" }
}
