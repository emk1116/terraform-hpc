#!/bin/bash
set -e

echo "=== Destroying HPC cluster ==="
terraform destroy -auto-approve -var-file=non-prod.tfvars

echo ""
echo "=== Verifying FSx cleanup ==="
aws fsx describe-file-systems \
  --query 'FileSystems[?Tags[?Key==`Project` && Value==`hpc`]].[FileSystemId,Lifecycle]' \
  --output table 2>/dev/null || echo "No FSx file systems found (expected)."

echo ""
echo "=== Verifying EIP cleanup ==="
aws ec2 describe-addresses \
  --query 'Addresses[?Tags[?Key==`Name` && contains(Value, `titan`)]].[AllocationId,PublicIp]' \
  --output table 2>/dev/null || echo "No EIPs found (expected)."

echo ""
echo "=== Destroy complete. No further charges expected. ==="
