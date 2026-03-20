output "bucket_name" {
  value       = aws_s3_bucket.hpc_data.id
  description = "S3 bucket name for HPC data pipeline"
}

output "bucket_arn" {
  value       = aws_s3_bucket.hpc_data.arn
  description = "S3 bucket ARN (used to scope IAM policies)"
}
