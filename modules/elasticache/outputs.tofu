output "endpoint_address" {
  description = "The primary endpoint address of the ElastiCache serverless cache"
  value       = aws_elasticache_serverless_cache.main.endpoint[0].address
}

output "endpoint_port" {
  description = "The primary endpoint port of the ElastiCache serverless cache"
  value       = aws_elasticache_serverless_cache.main.endpoint[0].port
}

output "reader_endpoint_address" {
  description = "The reader endpoint address of the ElastiCache serverless cache"
  value       = aws_elasticache_serverless_cache.main.reader_endpoint[0].address
}

output "reader_endpoint_port" {
  description = "The reader endpoint port of the ElastiCache serverless cache"
  value       = aws_elasticache_serverless_cache.main.reader_endpoint[0].port
}

output "arn" {
  description = "The ARN of the ElastiCache serverless cache"
  value       = aws_elasticache_serverless_cache.main.arn
}

output "status" {
  description = "The current status of the ElastiCache serverless cache"
  value       = aws_elasticache_serverless_cache.main.status
}

output "security_group_id" {
  description = "The ID of the ElastiCache security group"
  value       = aws_security_group.main.id
}