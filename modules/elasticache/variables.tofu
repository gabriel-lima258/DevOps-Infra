variable "cache_name" {
  description = "The unique identifier for the ElastiCache serverless cache"
  type        = string
}

variable "engine" {
  description = "The cache engine to use (valkey, redis, memcached)"
  type        = string
  default     = "valkey"
}

variable "major_engine_version" {
  description = "The major version of the cache engine (e.g. 9 for Valkey 9)"
  type        = string
  default     = "9"
}

variable "description" {
  description = "Description of the serverless cache"
  type        = string
  default     = ""
}

variable "data_storage_maximum" {
  description = "Maximum data storage limit in GB"
  type        = number
  default     = 5
}

variable "data_storage_minimum" {
  description = "Minimum data storage limit in GB"
  type        = number
  default     = 1
}

variable "ecpu_per_second_maximum" {
  description = "Maximum number of ECPUs per second"
  type        = number
  default     = 5000
}

variable "ecpu_per_second_minimum" {
  description = "Minimum number of ECPUs per second"
  type        = number
  default     = 1000
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain automatic snapshots (0 = disabled)"
  type        = number
  default     = 0
}

variable "daily_snapshot_time" {
  description = "Time to take daily snapshots in UTC (e.g. 05:00). Null disables scheduled snapshots."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "List of subnet IDs for the ElastiCache serverless cache"
  type        = list(string)
}

variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "security_group_config" {
  description = "Security group configuration for the ElastiCache serverless cache"
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