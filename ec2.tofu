resource "tls_private_key" "algadelivery" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "algadelivery" {
  key_name   = var.keypair_name
  public_key = tls_private_key.algadelivery.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.algadelivery.private_key_pem
  filename        = "${path.module}/${var.keypair_name}.pem"
  file_permission = "0400"
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = module.vpc.subnet_pub_ids["public"][0]
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.keypair_name
  associate_public_ip_address = true

  tags = merge(
    local.common_tags,
    {
      Name = "${local.context_name}-bastion"
    }
  )

  depends_on = [aws_key_pair.algadelivery]
}