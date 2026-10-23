variable "aws_region" {
  default = "us-east-1"
}

variable "environment" {
  description = "The environment for the S3 bucket (development, homolog, production)"
  type        = string
  default     = "development"
}

variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "172.25.0.0/16"
}

variable "vpc_name" {
  description = "The name of the VPC"
  type        = string
  default     = "algadelivery-vpc"
}

variable "subnet_pub_config" {
  description = "Configuration for public subnets grouped by name (e.g. public, dmz)"
  type = map(map(object({
    cidr_block = string
    az         = string
  })))
  default = {
    public = {
      "pub_a" = { cidr_block = "172.25.1.0/24", az = "a" },
      "pub_b" = { cidr_block = "172.25.2.0/24", az = "b" },
      "pub_c" = { cidr_block = "172.25.3.0/24", az = "c" }
    }
  }
}

variable "subnet_pvt_config" {
  description = "Configuration for private subnets grouped by name (e.g. management, cluster)"
  type = map(map(object({
    cidr_block = string
    az         = string
  })))
  default = {
    management = {
      "pvt_mgmt_a" = { cidr_block = "172.25.4.0/24", az = "a" },
      "pvt_mgmt_b" = { cidr_block = "172.25.5.0/24", az = "b" },
      "pvt_mgmt_c" = { cidr_block = "172.25.6.0/24", az = "c" }
    },
    cluster = {
      "pvt_cluster_a" = { cidr_block = "172.25.7.0/24", az = "a" },
      "pvt_cluster_b" = { cidr_block = "172.25.8.0/24", az = "b" },
      "pvt_cluster_c" = { cidr_block = "172.25.9.0/24", az = "c" }
    },
    database = {
      "pvt_db_a" = { cidr_block = "172.25.10.0/24", az = "a" },
      "pvt_db_b" = { cidr_block = "172.25.11.0/24", az = "b" },
      "pvt_db_c" = { cidr_block = "172.25.12.0/24", az = "c" }
    }
  }
}

variable "ngw_regional_mode" {
  description = "The availability mode regional"
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "The type of instance to use"
  type        = string
  default     = "t3.micro"
}

variable "keypair_name" {
  type    = string
  default = "algadelivery-bastion"
}

variable "ami_id" {
  description = "The ID of the AMI to use for the instance"
  type        = string
  default     = "ami-04680790a315cd58d"
}

variable "bastion_security_group_config" {
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
  default = null
}