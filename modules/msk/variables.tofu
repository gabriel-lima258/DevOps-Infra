variable "cluster_name" {
  description = "The name of the MSK Serverless cluster"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the MSK Serverless cluster"
  type        = list(string)
}

variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "security_group_config" {
  description = "Security group configuration for the MSK Serverless cluster"
  type = object({
    name        = string
    description = string
    ingress_rules = list(object({
      description = string
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = list(string)
    }))
    egress_rules = list(object({
      description = string
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = list(string)
    }))
  })
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}