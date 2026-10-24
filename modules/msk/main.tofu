resource "aws_msk_serverless_cluster" "main" {
  cluster_name = var.cluster_name

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.main.id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = merge(var.common_tags, {
    Name = var.cluster_name
  })

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_msk_bootstrap_brokers" "main" {
  cluster_arn = aws_msk_serverless_cluster.main.arn
}