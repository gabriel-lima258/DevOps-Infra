output "id" {
  description = "The ID of the instance"
  value       = aws_instance.main.id
}

output "arn" {
  description = "The ARN of the instance"
  value       = aws_instance.main.arn
}

output "public_ip" {
  description = "The public IP of the instance"
  value       = var.enabled_eip ? aws_eip.main[0].public_ip : aws_instance.main.public_ip
}

output "keypair_arn" {
  description = "The ARN of the key pair"
  value       = aws_key_pair.main.arn
}

output "security_group_id" {
  description = "ID security group"
  value       = aws_security_group.main.id
}