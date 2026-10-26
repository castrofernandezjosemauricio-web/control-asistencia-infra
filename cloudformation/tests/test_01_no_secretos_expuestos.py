"""Test 1 de 3: secretos generados, acceso minimo y sin exposicion."""
import re

from conftest import dump

SENSITIVE = re.compile(r"(password|secret|token|apikey|api_key)", re.I)
AWS_KEY = re.compile(r"AKIA[0-9A-Z]{16}")


def test_secretos_seguros(resources, templates):
    for fname, template in templates.items():
        for name, parameter in (template.get("Parameters") or {}).items():
            if SENSITIVE.search(name):
                assert parameter.get("NoEcho") is True, f"{fname}: parametro {name} sin NoEcho"
                assert "Default" not in parameter, f"{fname}: parametro {name} tiene Default"
        assert not AWS_KEY.search(dump(template)), f"{fname}: posible access key de AWS"

        for output_name, output in (template.get("Outputs") or {}).items():
            assert not SENSITIVE.search(output_name), f"{fname}: output sospechoso {output_name}"
            assert not SENSITIVE.search(dump(output.get("Value", ""))), (
                f"{fname}: output {output_name} expone secreto"
            )

        for name, resource in (template.get("Resources") or {}).items():
            properties = resource.get("Properties", {})
            for key, value in properties.items():
                if SENSITIVE.search(key) and isinstance(value, str):
                    raise AssertionError(f"{fname}:{name}.{key} contiene un literal")
            if resource["Type"] == "AWS::SecretsManager::Secret":
                generated = properties.get("GenerateSecretString")
                assert generated, f"{fname}:{name} no genera el secreto"
                assert generated.get("PasswordLength", 0) >= 24
                assert generated.get("ExcludePunctuation") is True
            if resource["Type"] == "AWS::EC2::Instance":
                user_data = dump(properties.get("UserData", ""))
                assert not re.search(r"\{\{resolve:secretsmanager:", user_data, re.I), (
                    f"{name}: no resolver secretos dentro de UserData"
                )
                assert not re.search(
                    r"(?i)(password|secret[_-]?key)\s*[:=]\s*['\"][^$'\"]{8,}['\"]",
                    user_data,
                ), f"{name}: posible secreto literal en UserData"

    profiles = {
        name: resource.get("Properties", {})
        for _, name, resource in resources
        if resource["Type"] == "AWS::IAM::InstanceProfile"
    }
    roles = {
        name: resource.get("Properties", {})
        for _, name, resource in resources
        if resource["Type"] == "AWS::IAM::Role"
    }
    instances = {
        name: resource.get("Properties", {})
        for _, name, resource in resources
        if resource["Type"] == "AWS::EC2::Instance"
    }
    frontend_profile = instances["FrontendInstance"]["IamInstanceProfile"]["Ref"]
    frontend_role_refs = profiles[frontend_profile]["Roles"]
    for role in frontend_role_refs:
        policies = dump(roles[role["Ref"]].get("Policies", []))
        assert "secretsmanager:GetSecretValue" not in policies, (
            "El rol de frontend no debe leer secretos del backend"
        )
