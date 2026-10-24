locals {
  context_name        = "algadelivery"
  ngw_regional_mode   = var.ngw_regional_mode ? "regional" : "zonal"
  internet_cidr_block = "0.0.0.0/0"
  my_public_ip        = "${trimspace(data.http.my_public_ip.response_body)}/32"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }

  bastion_security_group_config = var.bastion_security_group_config != null ? var.bastion_security_group_config : {
    name        = "${var.environment}-${local.context_name}-bastion-sg"
    description = "Security group for bastion host"
    ingress_rules = [
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
    egress_rules = [
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

  db_security_group_config = var.db_security_group_config != null ? var.db_security_group_config : {
    name        = "${var.environment}-${local.context_name}-db-sg"
    description = "Security group for DB instance"
    ingress_rules = [
      {
        description = "PostgreSQL para VPC"
        from_port   = local.db_port
        to_port     = local.db_port
        protocol    = "tcp"
        cidr_blocks = [var.vpc_cidr_block]
      }
    ]
    egress_rules = [
      {
        description = "Todo o trafego de saida"
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [local.internet_cidr_block]
      }
    ]
  }

  db_port = 5432

  cache_security_group_config = var.elasticache_security_group_config != null ? var.elasticache_security_group_config : {
    name        = "${var.environment}-${local.context_name}-valkey-sg"
    description = "Security group for ElastiCache Serverless Valkey in ${var.environment}"
    ingress_rules = [
      {
        description = "Valkey da VPC"
        from_port   = 6379
        to_port     = 6379
        protocol    = "tcp"
        cidr_blocks = [var.vpc_cidr_block]
      }
    ]
    egress_rules = [
      {
        description = "Todo o trafego de saida"
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [local.internet_cidr_block]
      }
    ]
  }

  msk_security_group_config = var.msk_security_group_config != null ? var.msk_security_group_config : {
    name        = "${var.environment}-${local.context_name}-msk-sg"
    description = "Security group for MSK Serverless cluster in ${var.environment}"
    ingress_rules = [
      {
        description = "Kafka IAM da VPC"
        from_port   = 9098
        to_port     = 9098
        protocol    = "tcp"
        cidr_blocks = [var.vpc_cidr_block]
      }
    ]
    egress_rules = [
      {
        description = "Todo o trafego de saida"
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [local.internet_cidr_block]
      }
    ]
  }

}
