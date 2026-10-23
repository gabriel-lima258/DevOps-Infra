module "bastion" {
  source = "../../modules/ec2"

  name                  = "${var.environment}-bastion"
  ami_id                = data.aws_ami.ubuntu.id
  vpc_id                = module.vpc.vpc_id
  common_tags           = local.common_tags
  instance_type         = var.instance_type
  keypair_name          = "${var.environment}-${var.keypair_name}"
  enabled_eip           = true
  subnet_id             = module.vpc.subnet_pub_ids["public"]["0"]
  security_group_config = local.bastion_security_group_config
}

# module "rancher" {
#   source = "../../modules/ec2"

#   name                  = "${var.environment}-rancher"
#   ami_id                = data.aws_ami.ubuntu.id
#   vpc_id                = module.vpc.vpc_id
#   common_tags           = local.common_tags
#   instance_type         = var.instance_type
#   keypair_name          = var.keypair_name
#   enabled_eip           = true
#   subnet_id             = module.vpc.subnet_pub_ids["public"]["0"]
#   security_group_config = local.bastion_security_group_config
# }