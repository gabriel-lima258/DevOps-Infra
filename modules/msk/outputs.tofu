output "arn" {
  description = "The ARN of the MSK Serverless cluster"
  value       = aws_msk_serverless_cluster.main.arn
}

output "bootstrap_brokers_sasl_iam" {
  description = "IAM bootstrap broker endpoints for the MSK Serverless cluster"
  value       = data.aws_msk_bootstrap_brokers.main.bootstrap_brokers_sasl_iam
}

output "security_group_id" {
  description = "The ID of the MSK security group"
  value       = aws_security_group.main.id
}