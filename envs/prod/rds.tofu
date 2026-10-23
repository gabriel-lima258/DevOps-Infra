module "database" {
  source = "../../modules/rds"

  db_name                = var.db_name
  db_identifier          = "${var.environment}-${var.db_identifier}"
  db_engine              = var.db_engine
  db_engine_version      = var.db_engine_version
  db_instance_class      = var.db_instance_class
  db_username            = var.db_username
  db_storage             = var.db_storage
  db_skip_final_snapshot = var.db_skip_final_snapshot
  db_port                = local.db_port

  vpc_id                = module.vpc.vpc_id
  db_subnet_ids         = module.vpc.subnet_pvt_ids["database"]
  db_subnet_group_name  = var.db_subnet_group_name
  security_group_config = local.db_security_group_config

  db_parameter_group_name    = var.db_parameter_group_name
  db_parameter_group_options = var.db_parameter_group_options

  common_tags = merge(
    local.common_tags, {
      "Name" = "${var.environment}-${var.db_identifier}"
  })
}