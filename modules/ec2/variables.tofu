variable "name" {
  type = string
}

variable "instance_type" {
  description = "The type of instance to use"
  type        = string
  default     = "t3.micro"
}

variable "keypair_name" {
  type = string
}

variable "ami_id" {
  description = "The ID of the AMI to use for the instance"
  type        = string
}

variable "security_group_config" {
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

variable "subnet_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}

variable "enabled_eip" {
  description = "Whether to associate an Elastic IP with the instance"
  type        = bool
  default     = true
}