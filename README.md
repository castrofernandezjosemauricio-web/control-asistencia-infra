# Control de asistencia: despliegue nuevo en AWS

Dos EC2: Django/PostgreSQL en backend y Angular/Nginx en frontend.
CloudFront ofrece HTTPS. Nginx publica Angular y reenvia /api al backend.
Cada EC2 clona su proyecto desde GitHub durante el primer arranque:
- Backend: https://github.com/GBAC22/control-asistencia-backend.git
- Frontend: https://github.com/GBAC22/control-asistencia-frontend.git

Subir los cambios de las aplicaciones a Git antes de desplegar. Los cambios
que solo existen en las carpetas locales no se instalan en AWS. Los repositorios
deben permitir clonacion HTTPS sin credenciales (repositorios publicos).
Si son privados, configurar autenticacion de despliegue antes de aplicar;
no poner tokens personales dentro de user_data.

## Organizacion

- versions.tf y providers.tf: herramientas y region AWS.
- variables.tf: nombre del despliegue, AMI fija, tipo EC2 y acceso SSH.
- network.tf: VPC, subred publica, Internet Gateway y rutas.
- security.tf: grupos separados; Django 8000 solo desde frontend.
- compute.tf y templates/: servidores, instalacion y servicios.
- secrets.tf: contrasenas aleatorias nuevas; no se muestran en outputs.
- ip.tf y cdn.tf: IP elastica y CloudFront HTTPS.
- backend.tf: backend S3; backend-nuevo.hcl selecciona el estado nuevo.
- outputs.tf: identificadores y direcciones de acceso.
- pulumi/: laboratorio independiente; Terraform no administra esos recursos.

## Estado nuevo: no migrar el estado parcial anterior

El bucket de estado existente se conserva. La nueva clave es:
control-asistencia/nuevo/terraform.tfstate

El estado parcial anterior sigue en control-asistencia/dev/terraform.tfstate.
No usar terraform init -migrate-state: copiaria las importaciones anteriores.
No usar terraform destroy con el backend anterior durante esta preparacion.
No eliminar el bucket de estado: tambien contiene el estado de Pulumi.
No subir estado, credenciales, .terraform, .build o planes a Git.

## Preparacion y despliegue (PowerShell)

Desde control-asistencia-infra, con Terraform 1.10+ disponible:

```powershell
$env:PATH = "C:\Program Files\Amazon\AWSCLIV2;$env:PATH"
$env:AWS_PROFILE = 'terraform'
$env:AWS_SDK_LOAD_CONFIG = '1'
aws.exe sts get-caller-identity
terraform init -reconfigure "-backend-config=backend-nuevo.hcl" "-backend-config=profile=terraform"
terraform state list
terraform validate
terraform plan -lock-timeout=5m -out=tfplan
```

En el primer despliegue, state list debe estar vacio (o informar que aun no
existe estado). Si aparecen recursos importados, detenerse: es el backend viejo.
Si el estado nuevo ya fue utilizado, no repetir la expectativa de estado vacio.

El plan inicial debe crear exactamente dos EC2 y los recursos auxiliares nuevos,
sin destruir ni reemplazar infraestructura anterior. Revisarlo antes de aplicar:

```powershell
terraform apply -lock-timeout=5m tfplan
terraform output
```

Terraform no espera que cloud-init termine de instalar Django/Angular. La
instalacion puede tardar varios minutos incluso despues del apply. CloudFront
espera su despliegue, pero eso tampoco verifica la salud de las aplicaciones.
Acceder por url_sistema HTTPS: las cookies de Django son seguras y requieren HTTPS.
Probar tambien url_health; debe responder correctamente antes de probar login.

## Diagnostico y primer administrador

EC2 -> instancia -> Conectar -> EC2 Instance Connect -> usuario ubuntu.
La AMI Ubuntu tiene que admitir EC2 Instance Connect; las plantillas tambien lo
instalan. El CIDR SSH por defecto corresponde al servicio en us-east-1; verificar
la lista de IP vigente de AWS si la conexion falla. No se necesita la llave vieja.

En cada servidor:

```bash
sudo cloud-init status --wait
sudo tail -n 80 /var/log/cloud-init-output.log
sudo test -f /var/lib/asistencia-ready && echo LISTO
```

Backend:

```bash
systemctl is-active django postgresql
curl -f http://127.0.0.1:8000/api/health
sudo -u asistencia /opt/backend/venv/bin/python /opt/backend/manage.py seed_admin --nombre "Administrador" --correo "admin@example.test"
```

seed_admin solicita la contrasena de forma interactiva. No hay un administrador
precargado. Los datos de alumnos y horarios se cargan desde la aplicacion.

Frontend:

```bash
sudo nginx -t
systemctl is-active nginx
```

No mostrar .env ni user_data durante una defensa: contienen secretos. No se usa
set -x en el arranque. Los secretos generados siguen presentes en el estado y en
user_data; el acceso IAM a ambos debe permanecer restringido.

## Trabajo de dos personas

Los dos equipos necesitan el mismo codigo de infraestructura, misma cuenta AWS, region, stack default y clave S3 nueva.
Cada persona usa sus propias credenciales autorizadas. La identidad root de la
sesion actual debe sustituirse por una identidad de trabajo antes del uso habitual.

1. A agrega una etiqueta DefensaA = "ok" en tags de la EC2 backend. Comparte el
   commit, genera el plan y aplica. No modificar user_data para esta demostracion.
2. B sincroniza Git, conserva DefensaA, agrega DefensaB = "ok" al frontend,
   genera un plan nuevo y aplica. Mostrar ambas etiquetas en AWS.
3. Ambos equipos usan el mismo commit del repositorio de infraestructura.
4. Para demostrar bloqueo, A deja apply esperando confirmacion; B ejecuta plan
   con -lock-timeout=15s. B debe esperar o fallar mientras A conserva el bloqueo.

No usar -lock=false ni force-unlock sobre una ejecucion activa. Un plan guardado
puede quedar obsoleto si otro aplica; generar uno nuevo despues de sincronizar.
El bloqueo evita escrituras simultaneas, pero no combina versiones del codigo.

## Actualizaciones desde Git

Terraform crea y configura los servidores; no hace git pull automaticamente
cuando se sube un commit de la aplicacion. Para actualizar un servidor existente,
conectarse por EC2 Instance Connect y actualizar el repositorio:

Backend (hacer respaldo de datos antes de migraciones):

```bash
sudo -u asistencia git -C /opt/backend pull --ff-only
sudo -u asistencia /opt/backend/venv/bin/pip install -r /opt/backend/requirements.txt gunicorn
sudo -u asistencia /opt/backend/venv/bin/python /opt/backend/manage.py migrate
sudo systemctl restart django
```

Frontend:

```bash
cd /opt/frontend
sudo git pull --ff-only
sudo npm ci
sudo npm run build
sudo cp -r dist/control-asistencia-web/browser/. /var/www/html/
sudo nginx -t
sudo systemctl reload nginx
```

No modificar en AWS los archivos versionados: los cambios se hacen en Git.
CloudFront tiene cache deshabilitada en esta configuracion.

## Limites del laboratorio

Backend en subred publica, con acceso a Django restringido por security group;
PostgreSQL local y discos cifrados, sin alta disponibilidad ni respaldos automaticos.
Las EC2 no necesitan credenciales AWS para clonar los repositorios publicos.
Cambiar user_data reemplaza la EC2 correspondiente; reemplazar backend
pierde los datos locales si no se hace respaldo. AMI fija evita cambios accidentales
por most_recent; antes del primer plan comprobar que siga disponible en la region.

## Limpieza

Las instancias viejas y los recursos anteriores se retiran por separado; no estan
administrados por el estado nuevo. Revisar discos, EIP y CloudFront antiguos.
Para el laboratorio Pulumi, preferir pulumi destroy desde pulumi/ para actualizar
su estado. No borrar estados como mecanismo de limpieza de recursos.
El bucket de estado existente no pertenece al ciclo de destruccion del despliegue.

## Validacion local

Se verifico sintaxis Bash de las plantillas y Terraform validate. El plan con AWS, apply, salud HTTPS y autenticacion quedan pendientes
hasta ejecutar los pasos de despliegue en la terminal con acceso AWS.
