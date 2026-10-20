"""Laboratorio: crear una EC2 y su red con Pulumi y Python.

Comandos desde esta carpeta:
    pulumi preview       -> muestra los cambios propuestos.
    pulumi up            -> aplica los cambios confirmados.
    pulumi stack output  -> muestra ID, IP y URL.

Pulumi compara este programa con el estado del stack guardado en S3.
Los nombres logicos ("vpc", "security", "vm", etc.) identifican recursos:
conservarlos evita que un simple cambio de nombre cree recursos diferentes.
"""

import pulumi
import pulumi_aws as aws

# 1. CONFIGURACION Y ETIQUETAS
# El stack es el entorno (dev). instanceType se configura con:
# pulumi config set instanceType t3.micro
config = pulumi.Config()
name = f"{pulumi.get_project()}-{pulumi.get_stack()}"
tags = {"Project": "control-asistencia", "ManagedBy": "Pulumi"}

# 2. VPC: red privada que contiene los recursos del laboratorio.
# /16 define el rango de direcciones privadas de esta red.
vpc = aws.ec2.Vpc(
    "vpc",
    cidr_block="10.20.0.0/16",
    enable_dns_hostnames=True,
    tags={**tags, "Name": name},
)

# 3. INTERNET GATEWAY: conecta la VPC con Internet.
gateway = aws.ec2.InternetGateway(
    "gateway",
    vpc_id=vpc.id,
    tags=tags,
)

# 4. SUBRED: segmento de la VPC donde se ubicara la instancia.
# map_public_ip_on_launch asigna una IPv4 publica al iniciar una EC2.
# Para tener acceso a Internet necesita ademas las rutas y reglas siguientes.
subnet = aws.ec2.Subnet(
    "subnet",
    vpc_id=vpc.id,
    cidr_block="10.20.1.0/24",
    map_public_ip_on_launch=True,
    tags=tags,
)

# 5. RUTAS: destinos que no son locales salen por el Internet Gateway.
# 0.0.0.0/0 representa cualquier destino IPv4.
routes = aws.ec2.RouteTable(
    "routes",
    vpc_id=vpc.id,
    routes=[{"cidr_block": "0.0.0.0/0", "gateway_id": gateway.id}],
    tags=tags,
)

# La asociacion indica que esta subred utiliza esta tabla de rutas.
association = aws.ec2.RouteTableAssociation(
    "association",
    subnet_id=subnet.id,
    route_table_id=routes.id,
)

# 6. SECURITY GROUP: firewall asociado a la interfaz de la instancia.
# ingress = ENTRADA: quien puede iniciar conexiones hacia la EC2.
# egress  = SALIDA: conexiones que la EC2 puede iniciar hacia otros destinos.
# Solo se permite el trafico definido; las respuestas a conexiones permitidas
# se autorizan automaticamente porque los security groups son stateful.
security = aws.ec2.SecurityGroup(
    "security",
    vpc_id=vpc.id,
    description="HTTP para laboratorio Pulumi",
    ingress=[
        {
            "protocol": "tcp",
            "from_port": 80,       # Inicio del rango de puertos.
            "to_port": 80,         # Fin: solo puerto 80 (HTTP).
            "cidr_blocks": ["0.0.0.0/0"],  # Desde cualquier IPv4.
        },
        # Para otra entrada, agregar otro diccionario a esta lista.
        # Ejemplo SSH: TCP, puertos 22-22, origen TU_IP_PUBLICA/32.
        # Abrir SSH tambien requiere usuario y autenticacion configurados.
        # Abrir 443 por si solo no instala ni configura HTTPS.
    ],
    egress=[
        {
            "protocol": "-1",      # Todos los protocolos y puertos.
            "from_port": 0,        # Con -1 estos limites no se usan.
            "to_port": 0,
            "cidr_blocks": ["0.0.0.0/0"],  # Cualquier destino IPv4.
        },
    ],
    tags=tags,
)

# 7. AMI: imagen del sistema operativo que se instalara en la EC2.
# Este propietario corresponde a Canonical; se busca Ubuntu 24.04 amd64.
# most_recent puede seleccionar otra AMI en el futuro y proponer un reemplazo:
# revisar siempre preview antes de aplicar.
ami = aws.ec2.get_ami(
    most_recent=True,
    owners=["099720109477"],
    filters=[
        {
            "name": "name",
            "values": [
                "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
            ],
        },
    ],
)

# 8. EC2: la maquina virtual. "vm" es su nombre logico en Pulumi.
# instance_type define la capacidad. subnet_id elige la red y el security
# group define el trafico permitido. Este ejemplo no configura llave SSH.
# user_data instala Nginx y publica la pagina durante el primer arranque.
# depends_on espera la asociacion de rutas antes de iniciar la instancia.
vm = aws.ec2.Instance(
    "vm",
    ami=ami.id,
    instance_type=config.get("instanceType") or "t3.micro",
    subnet_id=subnet.id,
    vpc_security_group_ids=[security.id],
    user_data="""#!/bin/bash
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx
printf '%s\n' '<h1>VM creada con Pulumi en AWS</h1>' > /var/www/html/index.html
systemctl enable --now nginx
""",
    tags={**tags, "Name": name},
    opts=pulumi.ResourceOptions(depends_on=[association]),
)

# 9. SALIDAS: AWS entrega estos valores despues de crear la instancia.
pulumi.export("instance_id", vm.id)
pulumi.export("public_ip", vm.public_ip)
pulumi.export("url", vm.public_ip.apply(lambda ip: f"http://{ip}"))

#nueva instancia
vm2 = aws.ec2.Instance(
    "vm2",  # Nombre logico del recurso dentro de Pulumi.
    ami=ami.id,
    instance_type="t3.micro",
    subnet_id=subnet.id,
    vpc_security_group_ids=[security.id],
    user_data=vm.user_data,
    # Nombre visible en la consola AWS: cambiar este texto a tu gusto.
    tags={**tags, "Name": "mi-segunda-instancia"},
    opts=pulumi.ResourceOptions(depends_on=[association]),
)
pulumi.export("segunda_instance_id", vm2.id)
pulumi.export("segunda_url", vm2.public_ip.apply(lambda ip: f"http://{ip}"))

# Tercera instancia: nombre logico unico y nombre visible en AWS.
# Reutiliza la subred, el firewall y la instalacion de Nginx.
vm3 = aws.ec2.Instance(
    "vm3",
    ami=ami.id,
    instance_type="t3.micro",
    subnet_id=subnet.id,
    vpc_security_group_ids=[security.id],
    user_data=vm.user_data,
    tags={**tags, "Name": "instancia practico 3"},
    opts=pulumi.ResourceOptions(depends_on=[association]),
)
pulumi.export("tercera_instance_id", vm3.id)
pulumi.export("tercera_url", vm3.public_ip.apply(lambda ip: f"http://{ip}"))
