"""Test 2 de 3: puertos privados cerrados y SSH/entrada web acotados."""

OPEN_CIDRS = {"0.0.0.0/0", "::/0"}
PRIVATE_PORTS = {22, 5432, 8000}


def _rules(resources):
    for _, name, resource in resources:
        properties = resource.get("Properties", {})
        if resource["Type"] == "AWS::EC2::SecurityGroup":
            for rule in properties.get("SecurityGroupIngress", []) or []:
                yield name, rule
        elif resource["Type"] == "AWS::EC2::SecurityGroupIngress":
            yield name, properties


def _ports(rule):
    return set(range(int(rule.get("FromPort", 0)), int(rule.get("ToPort", 0)) + 1))


def _is_open(rule):
    cidr_v4 = rule.get("CidrIp")
    cidr_v6 = rule.get("CidrIpv6")
    return (isinstance(cidr_v4, str) and cidr_v4 in OPEN_CIDRS) or (
        isinstance(cidr_v6, str) and cidr_v6 in OPEN_CIDRS
    )


def test_red_y_security_groups(resources, templates):
    ssh_default = templates["main.yaml"]["Parameters"]["SshCidr"]["Default"]
    assert int(ssh_default.split("/")[1]) >= 27, f"SSH default demasiado amplio: {ssh_default}"

    public_ports = set()
    found_django_rule = False
    for name, rule in _rules(resources):
        ports = _ports(rule)
        if _is_open(rule):
            assert rule.get("IpProtocol") != "-1", f"{name}: todos los puertos abiertos a Internet"
            exposed = ports & PRIVATE_PORTS
            assert not exposed, f"{name}: puertos {exposed} abiertos a Internet"
            public_ports |= ports
        if 22 in ports:
            assert rule.get("CidrIp") == {"Ref": "SshCidr"}, (
                f"{name}: SSH debe usar el parametro SshCidr"
            )
        if 8000 in ports:
            found_django_rule = True
            assert "CidrIp" not in rule and "CidrIpv6" not in rule, (
                f"{name}: Django 8000 no debe aceptar trafico por CIDR"
            )
            assert rule.get("SourceSecurityGroupId") == {"Ref": "FrontendSecurityGroup"}, (
                f"{name}: Django 8000 debe aceptar solo desde el SG frontend"
            )

    assert found_django_rule, "No se encontro regla de entrada para Django 8000"
    assert public_ports <= {80, 443}, f"Puertos publicos inesperados: {public_ports}"

    for _, name, resource in resources:
        if resource["Type"] != "AWS::EC2::SecurityGroup":
            continue
        for rule in resource.get("Properties", {}).get("SecurityGroupEgress", []) or []:
            assert rule.get("IpProtocol") == "tcp", f"{name}: egress no restringido a TCP"
            assert rule.get("FromPort") == rule.get("ToPort")
            assert rule.get("FromPort") in {80, 443}, f"{name}: puerto egress inesperado"
