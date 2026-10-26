# Control de asistencia en AWS CloudFormation

Esta implementación CloudFormation replica el despliegue Terraform de dos EC2: backend Django/PostgreSQL, frontend Angular/Nginx y CloudFront para HTTPS. La infraestructura se crea y administra dentro de un único stack.

## Incluye

- VPC `10.30.0.0/16`, subred pública `10.30.1.0/24`, Internet Gateway y ruta.
- Backend y frontend Ubuntu 24.04 (`t3.small` por defecto), discos gp3 de 16 GB cifrados e IMDSv2 obligatorio.
- Django/Gunicorn y PostgreSQL local en backend; Angular/Nginx en frontend.
- EIP para el frontend y CloudFront con redirección HTTP a HTTPS.
- Security groups: Django 8000 solo desde el frontend, PostgreSQL no expuesto, HTTP público y SSH limitado al CIDR configurado.
- Contraseña de PostgreSQL y clave de Django generadas en Secrets Manager. La instancia backend obtiene los valores con un rol IAM mínimo y no los recibe en user data.
- Señales de CloudFormation al terminar el arranque; el despliegue espera a que el health endpoint responda por HTTPS.

Los repositorios de aplicación deben permitir `git clone` HTTPS anónimo, igual que los configurados en los scripts de Terraform. Los cambios locales no publicados en dichos repositorios no se desplegarán.

## Requisitos

- Windows PowerShell 5.1 o PowerShell 7.
- AWS CLI v2 configurado con un perfil autorizado para CloudFormation, EC2, IAM, Secrets Manager y CloudFront. No uses root para despliegues habituales.
- Python 3.10+ y Git.
- Cuota suficiente para 2 EC2, EIP y CloudFront. CloudFront puede tardar varios minutos en desplegar.
- La AMI por defecto debe seguir disponible en `us-east-1`; puedes indicar otra Ubuntu 24.04 amd64 con `-AmiId`.

## Validar y probar localmente

Desde la raíz del repositorio:

```powershell
python -m pip install -r cloudformation\tests\requirements.txt
.\cloudformation\scripts\validate.ps1
```

La validación ejecuta `cfn-lint`, **exactamente tres tests pytest** y dos escáneres de IaC (Trivy y Checkov) sobre la plantilla ya renderizada. No crea recursos ni necesita credenciales AWS. Los tests comprueban secretos, exposición de red y cifrado/IMDSv2/HTTPS. `deploy.ps1` repite esta validación antes de crear el change set.

Instala Trivy además de las dependencias Python:

```powershell
winget install --id AquaSecurity.Trivy --exact --source winget
python -m pip install -r cloudformation\tests\requirements.txt
```

Los dos escáneres muestran sus hallazgos en consola en modo report-only/soft-fail para que se puedan revisar y explicar en la defensa. No significa que deban ignorarse: revisa especialmente reglas publicas, salida de red, logging y WAF, y documenta las decisiones aceptadas para el laboratorio.

En el escaneo local de esta plantilla Trivy reportó egress a cualquier destino (restringido a TCP 80/443, pero aún abierto a todos los CIDR), subred/EC2 con IP pública, ausencia de WAF y el TLS mínimo del certificado predeterminado de CloudFront. Checkov también señaló HTTP público hacia el origen, ausencia de CMK propia para Secrets Manager, logging de CloudFront y WAF/TLS. Estas alertas se dejan visibles para revisión; el template conserva el modelo del laboratorio. Para producción habría que restringir orígenes de red, usar WAF/logging, una llave KMS administrada por el equipo y un dominio/certificado propio, asumiendo sus costos y cambios.

## Desplegar

1. Revisa el CIDR que usarás para acceso administrativo. Cambia el valor predeterminado si la IP pública del operador no corresponde al CIDR de EC2 Instance Connect de tu región. No uses `0.0.0.0/0` para SSH.
2. Comprueba tus credenciales:

```powershell
aws sts get-caller-identity --profile terraform
```

3. Ejecuta la validación local y crea/revisa el change set:

```powershell
.\cloudformation\scripts\validate.ps1
.\cloudformation\scripts\deploy.ps1 -Environment dev -AwsProfile terraform -SshCidr "TU_IP_PUBLICA/32"
```

El script conserva los user data en los archivos de `userdata/`, construye una plantilla temporal, crea un change set, muestra sus cambios y solicita escribir `YES` antes de ejecutarlo. La plantilla temporal se elimina al terminar. Para automatizar la confirmación conscientemente, añade `-AutoApprove`.

Opciones útiles:

```powershell
.\cloudformation\scripts\deploy.ps1 -Environment dev -ProjectName asistencia-lab3-cfn -InstanceType t3.small -AmiId ami-xxxxxxxxxxxxxxxxx -Region us-east-1 -AwsProfile terraform
```

El script espera a `CREATE_COMPLETE`/`UPDATE_COMPLETE` y luego reintenta `url_health` hasta 10 minutos. La salida incluye `url_sistema`, `url_health`, IDs e IPs. CloudFront puede tardar más que la preparación de las EC2; si el health check final expira, revisa el stack y vuelve a consultar `url_health`.

Los valores base se leen desde `parameters\dev.json` o `parameters\prod.json`; los argumentos de PowerShell los pueden sobreescribir. `prod` solo separa el nombre/stack: la arquitectura sigue siendo un laboratorio de una sola zona, no un despliegue de alta disponibilidad.

## Preparar el primer administrador y usar la aplicación

1. Abre `url_sistema` en el navegador y valida que `/api/health` responda.
2. Conéctate al backend por EC2 Instance Connect desde la consola AWS (usuario `ubuntu`).
3. Crea el administrador de forma interactiva:

```bash
sudo -u asistencia /opt/backend/venv/bin/python /opt/backend/manage.py seed_admin --nombre "Administrador" --correo "admin@example.test"
```

La contraseña se solicita de forma interactiva. No imprimas `/opt/backend/.env`, `UserData` ni el valor de los secretos.

Para revisar cloud-init/servicios sin revelar secretos:

```bash
sudo cloud-init status --wait
systemctl is-active django postgresql
curl -f http://127.0.0.1:8000/api/health
```

Frontend:

```bash
sudo nginx -t
systemctl is-active nginx
```

## Actualizar, detectar drift y eliminar

Los cambios de infraestructura pasan por un change set nuevo. Cambiar user data reemplaza la instancia correspondiente; la base PostgreSQL local puede perderse. Haz respaldo antes de actualizar o destruir.

Detectar cambios manuales:

```powershell
.\cloudformation\scripts\drift.ps1 -StackName asistencia-lab3-cfn -Region us-east-1 -AwsProfile terraform
```

Eliminar todos los recursos gestionados por el stack (operación destructiva):

```powershell
.\cloudformation\scripts\destroy.ps1 -StackName asistencia-lab3-cfn -Region us-east-1 -AwsProfile terraform
```

El script pide confirmación de PowerShell y espera el borrado. No elimina recursos ni estado del stack Terraform existente. Usa un `ProjectName` distinto para mantener ambos despliegues separados.

## Tests de seguridad

Los tres tests están en `tests/` y corren sin AWS:

1. `test_01_no_secretos_expuestos.py`: busca claves literales, parámetros sensibles inseguros y exposición de secretos en user data/outputs.
2. `test_02_red_y_security_groups.py`: asegura que 22/8000/5432 no estén abiertos a Internet, que 8000 provenga del SG frontend y que SSH sea limitado.
3. `test_03_cifrado_y_transporte.py`: valida EBS cifrado, IMDSv2 obligatorio y HTTPS forzado en CloudFront.

```powershell
python -m pytest cloudformation\tests -v
```

`validate.ps1` es el comando recomendado para correr los tres tests y los dos escáneres juntos. Los tests estáticos no sustituyen una prueba dinámica del entorno ni un escáner de dependencias. Al borrar el stack, Secrets Manager puede mantener los secretos en recuperación temporal según su política de borrado; los nombres físicos son generados para no bloquear un despliegue posterior. Antes de producción agrega WAF, backups automatizados de PostgreSQL, endpoints privados y una estrategia de despliegue sin reemplazo.

## Limitaciones conocidas del laboratorio

- Una sola subred/una zona de disponibilidad, PostgreSQL en el disco local del backend, sin alta disponibilidad ni backups automáticos.
- La API se sirve bajo el mismo dominio del frontend, por lo que CORS no requiere orígenes separados. `CSRF_TRUSTED_ORIGINS` permite el patrón `https://*.cloudfront.net` porque el dominio asignado no se conoce antes de crear la distribución.
- El origen CloudFront recibe HTTP desde CloudFront a la instancia; el tráfico visitante sí se redirige a HTTPS. Django no tiene `SECURE_SSL_REDIRECT` porque el origen es HTTP, como en la configuración Terraform actual.
- Los grupos permiten salida completa a Internet para actualizaciones del SO y descarga de paquetes.
- `SshCidr` por defecto es el valor de laboratorio existente; limita el acceso a ese rango, pero debe ajustarse a la red administrativa real.
