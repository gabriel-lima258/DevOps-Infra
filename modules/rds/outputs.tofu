output "db_password_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "db_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "db_instance_id" {
  value = aws_db_instance.main.id
}

output "db_instance_arn" {
  value = aws_db_instance.main.arn
}
