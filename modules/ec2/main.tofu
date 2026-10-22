resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "main" {
  key_name   = var.keypair_name
  public_key = tls_private_key.main.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.main.private_key_pem
  filename        = "${path.root}/${var.keypair_name}.pem"
  file_permission = "0400"
}

resource "aws_eip" "main" {
  count    = var.enabled_eip ? 1 : 0
  instance = aws_instance.main.id
  domain   = "vpc"
}

resource "aws_instance" "main" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.main.id]
  key_name                    = var.keypair_name
  associate_public_ip_address = true

  tags = merge(
    var.common_tags,
    {
      Name = "${var.name}"
    }
  )

  depends_on = [aws_key_pair.main]
}