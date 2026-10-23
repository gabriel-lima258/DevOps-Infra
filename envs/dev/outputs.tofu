output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "vpc_arn" {
  description = "The ARN of the VPC"
  value       = module.vpc.vpc_arn
}

output "subnet_public_ids" {
  description = "The IDs of the public subnets"
  value       = module.vpc.subnet_pub_ids["public"]
}

output "subnet_public_arn" {
  description = "The ARNs of the public subnets"
  value       = module.vpc.subnet_pub_arns["public"]
}

output "subnet_pvt_mgmt_ids" {
  description = "The IDs of the private management subnets"
  value       = module.vpc.subnet_pvt_ids["management"]
}

output "subnet_pvt_mgmt_arns" {
  description = "The ARNs of the private management subnets"
  value       = module.vpc.subnet_pvt_arns["management"]
}
output "subnet_pvt_cluster_id" {
  description = "The IDs of the private cluster subnets"
  value       = module.vpc.subnet_pvt_ids["cluster"]
}

output "subnet_pvt_cluster_arn" {
  description = "The ARNs of the private cluster subnets"
  value       = module.vpc.subnet_pvt_arns["cluster"]
}

output "igw_id" {
  description = "The ID of the Internet Gateway"
  value       = module.vpc.igw_id
}

output "igw_arn" {
  description = "The ARN of the Internet Gateway"
  value       = module.vpc.igw_arn
}

output "ngw_id" {
  description = "The ID of the NAT Gateway"
  value       = module.vpc.ngw_id
}

output "route_table_public_id" {
  description = "The ID of the public route table"
  value       = module.vpc.route_table_public_id
}

output "route_table_private_id" {
  description = "The ID of the private route table"
  value       = module.vpc.route_table_private_id
}

output "bastion_id" {
  description = "The ID of the bastion instance"
  value       = module.bastion.id
}

output "bastion_arn" {
  description = "The ARN of the bastion instance"
  value       = module.bastion.arn
}

output "bastion_public_ip" {
  description = "The public IP of the bastion instance"
  value       = module.bastion.public_ip
}

output "keypair_arn" {
  description = "The ARN of the key pair"
  value       = module.bastion.keypair_arn
}

output "security_group_bastion_id" {
  description = "The ID of the bastion security group"
  value       = module.bastion.security_group_id
}

output "db_password_secret_arn" {
  value = module.database.db_password_secret_arn
}

output "db_endpoint" {
  value = module.database.db_endpoint
}

output "db_instance_id" {
  value = module.database.db_instance_id
}

output "db_instance_arn" {
  value = module.database.db_instance_arn
}

output "elasticache_endpoint_address" {
  description = "The primary endpoint address of the ElastiCache Valkey serverless cache"
  value       = module.elasticache.endpoint_address
}

output "elasticache_endpoint_port" {
  description = "The primary endpoint port of the ElastiCache Valkey serverless cache"
  value       = module.elasticache.endpoint_port
}

output "elasticache_reader_endpoint_address" {
  description = "The reader endpoint address of the ElastiCache Valkey serverless cache"
  value       = module.elasticache.reader_endpoint_address
}

output "elasticache_arn" {
  description = "The ARN of the ElastiCache Valkey serverless cache"
  value       = module.elasticache.arn
}

output "security_group_elasticache_id" {
  description = "The ID of the ElastiCache security group"
  value       = module.elasticache.security_group_id
}
