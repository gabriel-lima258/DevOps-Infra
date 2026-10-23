module "vpc" {
  source = "../../modules/vpc"

  aws_region        = var.aws_region
  context_name      = local.context_name
  vpc_cidr_block    = var.vpc_cidr_block
  vpc_name          = "${var.environment}-${local.context_name}-vpc"
  subnet_pub_config = var.subnet_pub_config
  subnet_pvt_config = var.subnet_pvt_config
  ngw_regional_mode = local.ngw_regional_mode
  common_tags       = local.common_tags
}