module "msk" {
  source = "../../modules/msk"

  cluster_name          = "${var.environment}-${local.context_name}-msk"
  subnet_ids            = module.vpc.subnet_pvt_ids["management"]
  vpc_id                = module.vpc.vpc_id
  security_group_config = local.msk_security_group_config
  common_tags           = local.common_tags
}