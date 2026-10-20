# Frontend: HTTP para CloudFront; SSH limitado a EC2 Instance Connect.
resource "aws_security_group" "frontend" {
  name_prefix = "${var.project_name}-front-"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "EC2 Instance Connect"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# Backend: Django solo recibe trafico desde el grupo del frontend.
# PostgreSQL permanece en localhost, sin abrir el puerto 5432.
resource "aws_security_group" "backend" {
  name_prefix = "${var.project_name}-back-"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    description     = "Django desde frontend"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }
  ingress {
    description = "EC2 Instance Connect"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# Acceso por la consola con EC2 Instance Connect; no requiere la llave perdida.
