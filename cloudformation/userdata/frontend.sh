#!/bin/bash
set -Eeuo pipefail

signal_stack() {
  local status="$1"
  aws cloudformation signal-resource \
    --region "@@AWS_REGION@@" \
    --stack-name "@@STACK_NAME@@" \
    --logical-resource-id FrontendInstance \
    --status "$status" \
    --unique-id "$(hostname)"
}

on_error() {
  signal_stack FAILURE || true
  exit 1
}
trap on_error ERR

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y awscli curl ec2-instance-connect nginx
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource.sh
bash /tmp/nodesource.sh
apt-get install -y nodejs

git clone https://github.com/GBAC22/control-asistencia-frontend.git /opt/frontend
cd /opt/frontend
npm ci
npm run build
cp -r dist/control-asistencia-web/browser/. /var/www/html/
cat > /etc/nginx/sites-available/default <<'NGINX'
server {
  listen 80 default_server;
  root /var/www/html;
  index index.html;
  client_max_body_size 12m;
  location /api/ {
    proxy_pass http://@@BACKEND_PRIVATE_IP@@:8000;
    proxy_set_header Host @@BACKEND_PRIVATE_IP@@;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_connect_timeout 10s;
    proxy_read_timeout 60s;
  }
  location / {
    try_files $uri $uri/ /index.html;
  }
}
NGINX
nginx -t
systemctl enable nginx
systemctl restart nginx
touch /var/lib/asistencia-ready
trap - ERR
signal_stack SUCCESS
