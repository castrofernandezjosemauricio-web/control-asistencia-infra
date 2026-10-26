#!/bin/bash
set -Eeuo pipefail
umask 077

signal_stack() {
  local status="$1"
  aws cloudformation signal-resource \
    --region "@@AWS_REGION@@" \
    --stack-name "@@STACK_NAME@@" \
    --logical-resource-id BackendInstance \
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
apt-get install -y awscli build-essential curl ec2-instance-connect git libpq-dev postgresql python3-dev python3-pip python3-venv
systemctl enable --now postgresql

DB_PASSWORD="$(aws secretsmanager get-secret-value --region "@@AWS_REGION@@" --secret-id "@@DATABASE_SECRET_ARN@@" --query SecretString --output text)"
DJANGO_SECRET="$(aws secretsmanager get-secret-value --region "@@AWS_REGION@@" --secret-id "@@DJANGO_SECRET_ARN@@" --query SecretString --output text)"
if [ -z "$DB_PASSWORD" ] || [ -z "$DJANGO_SECRET" ]; then
  echo "No fue posible obtener los secretos del backend" >&2
  exit 1
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE USER asistencia WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE control_asistencia OWNER asistencia;"

git clone https://github.com/GBAC22/control-asistencia-backend.git /opt/backend
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
cat > /opt/backend/.env <<ENV
DJANGO_SECRET_KEY=$DJANGO_SECRET
DJANGO_DEBUG=false
DJANGO_ALLOWED_HOSTS=$PRIVATE_IP,localhost,127.0.0.1
POSTGRES_DB=control_asistencia
POSTGRES_USER=asistencia
POSTGRES_PASSWORD=$DB_PASSWORD
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
TIME_ZONE=America/La_Paz
CORS_ALLOWED_ORIGINS=
CSRF_TRUSTED_ORIGINS=https://*.cloudfront.net
SECURE_SSL_REDIRECT=false
SECURE_HSTS_SECONDS=0
ENV
unset DB_PASSWORD DJANGO_SECRET

useradd --system --home /opt/backend --shell /usr/sbin/nologin asistencia
chown -R asistencia:asistencia /opt/backend
cd /opt/backend
sudo -u asistencia python3 -m venv venv
sudo -u asistencia ./venv/bin/pip install -r requirements.txt gunicorn
sudo -u asistencia ./venv/bin/python manage.py migrate

cat > /etc/systemd/system/django.service <<'SERVICE'
[Unit]
Description=Control asistencia Django Gunicorn
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
User=asistencia
Group=asistencia
WorkingDirectory=/opt/backend
ExecStart=/opt/backend/venv/bin/gunicorn config.wsgi:application --bind 0.0.0.0:8000 --workers 2 --access-logfile - --error-logfile -
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable --now django
curl --retry 20 --retry-delay 5 --retry-connrefused --fail http://127.0.0.1:8000/api/health
touch /var/lib/asistencia-ready
trap - ERR
signal_stack SUCCESS
