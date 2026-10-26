# CloudFormation: implementacion y guia

La migracion ya esta implementada en [cloudformation/](../cloudformation/). Este archivo conserva el resumen de arquitectura; la guia de ejecucion completa, comandos y tests esta en [cloudformation/README.md](../cloudformation/README.md).

## Objetivo

Replicar con una sola plantilla de AWS CloudFormation el comportamiento de la infraestructura Terraform:

- VPC, subred publica, Internet Gateway y rutas.
- Dos EC2 Ubuntu: backend Django/Gunicorn con PostgreSQL local y frontend Angular/Nginx.
- Elastic IP para frontend y CloudFront con redirect HTTP a HTTPS.
- Security groups equivalentes, IMDSv2, discos gp3 cifrados y outputs de IPs, IDs y URLs.
- Instalacion de aplicaciones en user data y `CreationPolicy`/`SignalResource` para esperar la preparacion.

## Lenguajes

- **YAML:** plantilla declarativa `cloudformation/templates/main.yaml`.
- **Bash:** user data en `cloudformation/userdata/`.
- **PowerShell:** renderizado, validacion, despliegue, drift y eliminacion.
- **Python/pytest:** tests estaticos de seguridad.

## Estructura implementada

```text
cloudformation/
|-- README.md
|-- templates/main.yaml
|-- userdata/backend.sh
|-- userdata/frontend.sh
|-- parameters/dev.json
|-- parameters/prod.json
|-- scripts/
|   |-- render-template.ps1
|   |-- validate.ps1
|   |-- deploy.ps1
|   |-- drift.ps1
|   `-- destroy.ps1
`-- tests/
    |-- conftest.py
    |-- requirements.txt
    |-- test_01_no_secretos_expuestos.py
    |-- test_02_red_y_security_groups.py
    `-- test_03_cifrado_y_transporte.py
```

## Seguridad

Hay exactamente tres tests pytest: (1) secretos/privilegios, (2) reglas de red y (3) cifrado/IMDSv2/HTTPS. La validacion tambien ejecuta dos escaneres del template renderizado: Trivy y Checkov.

Validacion local desde la raiz:

```powershell
python -m pip install -r cloudformation\tests\requirements.txt
.\cloudformation\scripts\validate.ps1
```

La plantilla cambia los nombres de output de Terraform (que contienen `_`, no permitidos en los IDs de output CloudFormation) a `IpBackend`, `IpFrontend`, `BackendId`, `FrontendId`, `UrlSistema` y `UrlHealth`. El script de despliegue muestra los alias equivalentes a Terraform.

No se desplegaron recursos AWS durante la preparacion; sigue la guia para revisar el change set y aplicar en una cuenta autorizada.
