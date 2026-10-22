output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_arn" {
  description = "The ARN of the VPC"
  value       = aws_vpc.main.arn
}

output "subnet_pub_ids" {
  description = "The IDs of the public subnets"
  # value       = [for subnet in aws_subnet.public : subnet.id]
  value = {
    for group_name in keys(var.subnet_pub_config) :
    group_name => [
      for k, subnet in aws_subnet.public : subnet.id
      if local.subnet_pub_config[k].group == group_name
    ]
  }
}

output "subnet_pub_arns" {
  description = "The ARNs of the public subnets"
  value = {
    for group_name in keys(var.subnet_pub_config) :
    group_name => [
      for k, subnet in aws_subnet.public : subnet.arn
      if local.subnet_pub_config[k].group == group_name
    ]
  }
}

output "subnet_pvt_ids" {
  description = "The IDs of the private management subnets"
  value = {
    for group_name in keys(var.subnet_pvt_config) :
    group_name => [
      for k, subnet in aws_subnet.private : subnet.id
      if local.subnet_pvt_config[k].group == group_name
    ]
  }
}

output "subnet_pvt_arns" {
  description = "The ARNs of the private management subnets"
  value = {
    for group_name in keys(var.subnet_pvt_config) :
    group_name => [
      for k, subnet in aws_subnet.private : subnet.arn
      if local.subnet_pvt_config[k].group == group_name
    ]
  }
}

output "igw_id" {
  description = "The ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "igw_arn" {
  description = "The ARN of the Internet Gateway"
  value       = aws_internet_gateway.main.arn
}

output "ngw_id" {
  description = "The ID of the NAT Gateway"
  value       = aws_nat_gateway.main.id
}

output "route_table_public_id" {
  description = "The ID of the public route table"
  value       = aws_route_table.public.id
}

output "route_table_private_id" {
  description = "The ID of the private route table"
  value       = aws_route_table.private.id
}