module "elasticache" {
  source = "../../modules/elasticache"

  cache_name           = "${var.environment}-${local.context_name}-valkey"
  engine               = "valkey"
  major_engine_version = var.elasticache_major_engine_version
  description          = "ElastiCache Serverless Valkey for ${local.context_name}"

  data_storage_maximum    = var.elasticache_data_storage_maximum
  data_storage_minimum    = var.elasticache_data_storage_minimum
  ecpu_per_second_maximum = var.elasticache_ecpu_per_second_maximum
  ecpu_per_second_minimum = var.elasticache_ecpu_per_second_minimum

  snapshot_retention_limit = var.elasticache_snapshot_retention_limit
  daily_snapshot_time      = var.elasticache_daily_snapshot_time

  subnet_ids            = module.vpc.subnet_pvt_ids["management"]
  vpc_id                = module.vpc.vpc_id
  security_group_config = local.cache_security_group_config
  common_tags           = local.common_tags
}