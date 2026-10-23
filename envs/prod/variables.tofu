variable "aws_region" {
  default = "us-east-1"
}

variable "environment" {
  description = "The environment for the S3 bucket (development, homolog, production)"
  type        = string
  default     = "production"
}

variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "172.26.0.0/16"
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
      "pub_a" = { cidr_block = "172.26.1.0/24", az = "a" },
      "pub_b" = { cidr_block = "172.26.2.0/24", az = "b" },
      "pub_c" = { cidr_block = "172.26.3.0/24", az = "c" }
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
      "pvt_mgmt_a" = { cidr_block = "172.26.4.0/24", az = "a" },
      "pvt_mgmt_b" = { cidr_block = "172.26.5.0/24", az = "b" },
      "pvt_mgmt_c" = { cidr_block = "172.26.6.0/24", az = "c" }
    },
    cluster = {
      "pvt_cluster_a" = { cidr_block = "172.26.7.0/24", az = "a" },
      "pvt_cluster_b" = { cidr_block = "172.26.8.0/24", az = "b" },
      "pvt_cluster_c" = { cidr_block = "172.26.9.0/24", az = "c" }
    },
    database = {
      "pvt_db_a" = { cidr_block = "172.26.10.0/24", az = "a" },
      "pvt_db_b" = { cidr_block = "172.26.11.0/24", az = "b" },
      "pvt_db_c" = { cidr_block = "172.26.12.0/24", az = "c" }
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

variable "db_subnet_group_name" {
  description = "The name of the DB subnet group"
  type        = string
  default     = "algadelivery-db-subnet-group"
}

variable "db_parameter_group_name" {
  description = "The name of the DB parameter group"
  type        = string
  default     = "algadelivery-db-parameter-group"
}

variable "db_parameter_group_options" {
  description = "The options for the DB parameter group"
  type        = map(string)
  default = {
    max_connections          = "300"
    shared_preload_libraries = "pg_stat_statements,pgaudit"
  }

}

variable "db_engine" {
  description = "The database engine to use"
  type        = string
  default     = "postgres"
}

variable "db_engine_version" {
  description = "The version of the database engine to use"
  type        = string
  default     = "18"
}

variable "db_name" {
  description = "Db Name"
  type        = string
  default     = "delivery"
}

variable "db_instance_class" {
  description = "The instance class for the DB instance"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_username" {
  description = "The username for the DB instance"
  type        = string
  default     = "postgres"
}

variable "db_storage" {
  description = "The amount of storage to allocate for the DB instance"
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Whether to create a Multi-AZ DB instance"
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Whether to skip the final snapshot when deleting the DB instance"
  type        = bool
  default     = true
}

variable "db_identifier" {
  description = "The identifier for the DB instance"
  type        = string
  default     = "algadelivery-db"
}

variable "db_port" {
  description = "Db port"
  type        = number
  default     = 5432
}

variable "db_security_group_config" {
  description = "The security group configuration for the DB instance"
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

variable "db_backup_retention_period" {
  description = "The number of days to retain backup copies"
  type = string
  default = "10"
}

variable "db_backup_window" {
  description = "The time window for database backups"
  type = string
  default = "02:00-03:00"
}

variable "db_maintenance_window" {
  description = "The maintenance window for the DB instance"
  type = string
  default = "Mon:03:00-Mon:04:00"
}

# ElastiCache Serverless
variable "elasticache_major_engine_version" {
  description = "The major version of the Valkey engine (e.g. 8)"
  type        = string
  default     = "8"
}

variable "elasticache_data_storage_maximum" {
  description = "Maximum data storage limit in GB"
  type        = number
  default     = 5
}

variable "elasticache_data_storage_minimum" {
  description = "Minimum data storage limit in GB"
  type        = number
  default     = 1
}

variable "elasticache_ecpu_per_second_maximum" {
  description = "Maximum number of ECPUs per second"
  type        = number
  default     = 5000
}

variable "elasticache_ecpu_per_second_minimum" {
  description = "Minimum number of ECPUs per second"
  type        = number
  default     = 1000
}

variable "elasticache_snapshot_retention_limit" {
  description = "Number of days to retain automatic snapshots (0 = disabled)"
  type        = number
  default     = 0
}

variable "elasticache_daily_snapshot_time" {
  description = "Time to take daily snapshots in UTC (e.g. 05:00). Null disables scheduled snapshots."
  type        = string
  default     = null
}

variable "elasticache_security_group_config" {
  description = "Security group configuration for ElastiCache. When null, a default is generated from vpc_cidr_block."
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