output "public_ip" {
  value = aws_eip.head_node.public_ip
}

output "private_ip" {
  value = aws_instance.head_node.private_ip
}

output "instance_id" {
  value = aws_instance.head_node.id
}
