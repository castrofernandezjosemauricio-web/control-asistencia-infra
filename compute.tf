resource "aws_instance" "backend" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.subnet.id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  user_data_replace_on_change = true
  metadata_options { http_tokens = "required" }
  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    encrypted   = true
  }
  tags = { Name = "control-asistencia-backend" }
  user_data = templatefile("${path.module}/templates/backend.sh.tftpl", {
    db_password   = random_password.db.result
    django_secret = random_password.django_secret.result
    frontend_ip   = aws_eip.frontend.public_ip
    domain        = aws_cloudfront_distribution.cdn.domain_name
  })
  depends_on = [aws_route_table_association.rta]
}
resource "aws_instance" "frontend" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.subnet.id
  vpc_security_group_ids      = [aws_security_group.frontend.id]
  user_data_replace_on_change = true
  metadata_options { http_tokens = "required" }
  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    encrypted   = true
  }
  tags = { Name = "control-asistencia-frontend" }
  user_data = templatefile("${path.module}/templates/frontend.sh.tftpl", {
    backend_ip = aws_instance.backend.private_ip
  })
  depends_on = [aws_route_table_association.rta]
}
