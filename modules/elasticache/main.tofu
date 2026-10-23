resource "aws_elasticache_serverless_cache" "main" {
  name        = var.cache_name
  engine      = var.engine
  description = var.description

  major_engine_version = var.major_engine_version

  cache_usage_limits {
    data_storage {
      maximum = var.data_storage_maximum
      minimum = var.data_storage_minimum
      unit    = "GB"
    }

    ecpu_per_second {
      maximum = var.ecpu_per_second_maximum
      minimum = var.ecpu_per_second_minimum
    }
  }

  subnet_ids         = var.subnet_ids
  security_group_ids = [aws_security_group.main.id]

  snapshot_retention_limit = var.snapshot_retention_limit
  daily_snapshot_time      = var.daily_snapshot_time

  tags = merge(var.common_tags, {
    Name = var.cache_name
  })

  lifecycle {
    prevent_destroy = true
  }
}