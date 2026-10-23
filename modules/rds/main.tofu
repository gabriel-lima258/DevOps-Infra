resource "aws_db_subnet_group" "main" {
  name       = var.db_subnet_group_name
  subnet_ids = var.db_subnet_ids

  tags = merge(
    var.common_tags, {
      Name = var.db_subnet_group_name
    }
  )
}

resource "aws_db_parameter_group" "main" {
  name   = var.db_parameter_group_name
  family = "${var.db_engine}${var.db_engine_version}"


  dynamic "parameter" {
    for_each = var.db_parameter_group_options
    content {
      name         = parameter.key
      value        = parameter.value
      apply_method = "pending-reboot"
    }
  }

  tags = merge(
    var.common_tags, {
      Name = var.db_parameter_group_name
    }
  )
}

resource "aws_db_instance" "main" {
  identifier        = var.db_identifier
  db_name           = var.db_name
  engine            = var.db_engine
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_storage

  username                    = var.db_username
  manage_master_user_password = true
  port                        = var.db_port

  parameter_group_name   = aws_db_parameter_group.main.name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.main.id]

  backup_retention_period = var.db_backup_retention_period
  backup_window           = var.db_backup_window
  maintenance_window      = var.db_maintenance_window

  multi_az = false

  skip_final_snapshot = var.db_skip_final_snapshot

  apply_immediately = true

  tags = merge(
    var.common_tags, {
      Name = var.db_parameter_group_name
    }
  )
}