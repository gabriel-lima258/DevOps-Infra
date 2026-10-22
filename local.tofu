locals {
  context_name        = "algadelivery"
  ngw_regional_mode   = var.ngw_regional_mode ? "regional" : "zonal"
  internet_cidr_block = "0.0.0.0/0"
  my_public_ip        = "${trimspace(data.http.my_public_ip.response_body)}/32"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }

  bastion_ingress_rules = length(var.bastion_ingress_rules) > 0 ? var.bastion_ingress_rules : [
    {
      description = "SSH para minha maquina"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [local.my_public_ip]
    },
    {
      description = "HTTP para VPC"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]
    },
    {
      description = "HTTPS para VPC"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]
    }
  ]

  bastion_egress_rules = length(var.bastion_egress_rules) > 0 ? var.bastion_egress_rules : [
    {
      description = "Todo o trafego de saida"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = [local.internet_cidr_block]
    },
    {
      description = "HTTP para VPC"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [local.internet_cidr_block]
    }
  ]
}