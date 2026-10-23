variable "db_subnet_group_name" {
  description = "The name of the DB subnet group"
  type        = string
}

variable "db_parameter_group_name" {
  description = "The name of the DB parameter group"
  type        = string
}

variable "db_parameter_group_options" {
  description = "The options for the DB parameter group"
  type        = map(string)
}

variable "db_engine" {
  description = "The database engine to use"
  type        = string
}

variable "db_engine_version" {
  description = "The version of the database engine to use"
  type        = string
}

variable "db_name" {
  description = "Db Name"
  type        = string
}

variable "db_instance_class" {
  description = "The instance class for the DB instance"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_username" {
  description = "The username for the DB instance"
  type        = string
}

variable "db_storage" {
  description = "The amount of storage to allocate for the DB instance"
  type        = number
  default     = 20
}

variable "db_skip_final_snapshot" {
  description = "Whether to skip the final snapshot when deleting the DB instance"
  type        = bool
  default     = true
}

variable "db_identifier" {
  description = "The identifier for the DB instance"
  type        = string
}

variable "db_port" {
  description = "Db port"
  type        = number
}

variable "db_subnet_ids" {
  description = "The IDs of the subnets for the DB instance"
  type        = list(string)
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
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

variable "vpc_id" {
  type = string
}