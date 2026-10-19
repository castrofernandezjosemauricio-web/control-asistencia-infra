terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Contraseñas generadas automáticamente
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "django_secret" {
  length  = 50
  special = false
}

# Ubuntu 24.04 más reciente
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# Red
resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "vpc-control-asistencia" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_subnet" "subnet" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "snet-app" }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.subnet.id
  route_table_id = aws_route_table.rt.id
}

# Reglas de seguridad
resource "aws_security_group" "sg" {
  name   = "control-asistencia-sg"
  vpc_id = aws_vpc.vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Django interno"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Llave SSH
resource "aws_key_pair" "key" {
  key_name   = "control-asistencia"
  public_key = file(pathexpand("~/.ssh/control-asistencia.pub"))
}

# IP fija del frontend. Se crea antes que las instancias para que el backend
# conozca el origen real sin crear una dependencia circular.
resource "aws_eip" "frontend" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "eip-frontend-control-asistencia" }
}

resource "aws_eip_association" "frontend" {
  instance_id   = aws_instance.frontend.id
  allocation_id = aws_eip.frontend.id
}



# HTTPS con CloudFront
resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  wait_for_deployment = false

  origin {
    domain_name = "ec2-${replace(aws_eip.frontend.public_ip, ".", "-")}.compute-1.amazonaws.com"
    origin_id   = "frontend"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "frontend"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}


# Servidor backend: Django + PostgreSQL
resource "aws_instance" "backend" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.subnet.id
  vpc_security_group_ids      = [aws_security_group.sg.id]
  key_name                    = aws_key_pair.key.key_name
  user_data_replace_on_change = true
  tags                        = { Name = "backend-control-asistencia" }

  user_data = <<-EOF
    #!/bin/bash
    set -ex
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git python3-venv python3-pip python3-dev build-essential libpq-dev postgresql

    # Base de datos
    sudo -u postgres psql -c "CREATE USER asistencia WITH PASSWORD '${random_password.db.result}';"
    sudo -u postgres psql -c "CREATE DATABASE control_asistencia OWNER asistencia;"

    # Código
    git clone https://github.com/GBAC22/control-asistencia-backend.git /opt/backend
    cd /opt/backend
    python3 -m venv venv
    ./venv/bin/pip install -r requirements.txt gunicorn

    # Configuración
    PRIVATE_IP=$(hostname -I | awk '{print $1}')
    cat > .env <<ENV
    DJANGO_SECRET_KEY=${random_password.django_secret.result}
    DJANGO_DEBUG=false
    DJANGO_ALLOWED_HOSTS=$PRIVATE_IP,localhost,127.0.0.1,${aws_eip.frontend.public_ip}
    POSTGRES_DB=control_asistencia
    POSTGRES_USER=asistencia
    POSTGRES_PASSWORD=${random_password.db.result}
    POSTGRES_HOST=localhost
    POSTGRES_PORT=5432
    TIME_ZONE=America/La_Paz
    CORS_ALLOWED_ORIGINS=https://${aws_cloudfront_distribution.cdn.domain_name}
    CSRF_TRUSTED_ORIGINS=https://${aws_cloudfront_distribution.cdn.domain_name}
    SECURE_SSL_REDIRECT=false
    SECURE_HSTS_SECONDS=0
    SECURE_HSTS_INCLUDE_SUBDOMAINS=false
    SECURE_HSTS_PRELOAD=false
    ENV
    sed -i 's/^[ ]*//' .env
    chmod 600 .env

    ./venv/bin/python manage.py migrate

    # Servicio
    cat > /etc/systemd/system/django.service <<SVC
    [Unit]
    Description=Django Gunicorn
    After=network.target postgresql.service

    [Service]
    WorkingDirectory=/opt/backend
    ExecStart=/opt/backend/venv/bin/gunicorn config.wsgi:application --bind 0.0.0.0:8000
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVC
    systemctl daemon-reload
    systemctl enable --now django
  EOF
}

# Servidor frontend: Angular + Nginx
resource "aws_instance" "frontend" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.subnet.id
  vpc_security_group_ids      = [aws_security_group.sg.id]
  key_name                    = aws_key_pair.key.key_name
  user_data_replace_on_change = true
  tags                        = { Name = "frontend-control-asistencia" }

  user_data = <<-EOF
    #!/bin/bash
    set -ex
    export DEBIAN_FRONTEND=noninteractive

    # Memoria extra para compilar Angular
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    apt-get update
    apt-get install -y git nginx curl
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs

    git clone https://github.com/GBAC22/control-asistencia-frontend.git /opt/frontend
    cd /opt/frontend
    npm ci
    npm run build

    rm -rf /var/www/html/*
    cp -r $(dirname $(find dist -name index.html | head -1))/. /var/www/html/

    cat > /etc/nginx/sites-available/default <<NGX
    server {
      listen 80 default_server;
      root /var/www/html;
      index index.html;

      location /api/ {
        proxy_pass http://${aws_instance.backend.private_ip}:8000;
        proxy_set_header Host ${aws_instance.backend.private_ip};
        proxy_set_header X-Real-IP \$remote_addr;
      }

      location / {
        try_files \$uri \$uri/ /index.html;
      }
    }
    NGX
    systemctl restart nginx
  EOF
}

output "ip_backend" {
  value = aws_instance.backend.public_ip
}

output "ip_frontend" {
  value = aws_eip.frontend.public_ip
}

output "url_sistema" {
  value = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}

output "ssh_backend" {
  value = "ssh -i ~/.ssh/control-asistencia ubuntu@${aws_instance.backend.public_ip}"
}

output "ssh_frontend" {
  value = "ssh -i ~/.ssh/control-asistencia ubuntu@${aws_eip.frontend.public_ip}"
}