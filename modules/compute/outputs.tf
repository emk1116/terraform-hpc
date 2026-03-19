output "head_node_ip" {
  value = aws_eip.head_node_eip.public_ip
}

output "compute_node_ip" {
  value = aws_instance.compute_node.public_ip
}
