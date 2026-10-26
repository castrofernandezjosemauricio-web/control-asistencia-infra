import json
import os
from pathlib import Path

import pytest
import yaml

DEFAULT_DIR = Path(__file__).resolve().parents[2] / "cloudformation" / "templates"


class _CfnLoader(yaml.SafeLoader):
    pass


def _tag(loader, suffix, node):
    # Convierte !Ref, !Sub, !GetAtt... en {"Ref": ...} / {"Fn::Sub": ...}
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        value = loader.construct_mapping(node, deep=True)
    key = "Ref" if suffix == "Ref" else f"Fn::{suffix}"
    return {key: value}


_CfnLoader.add_multi_constructor("!", _tag)


@pytest.fixture(scope="session")
def templates():
    folder = Path(os.environ.get("TEMPLATES_DIR", DEFAULT_DIR))
    files = sorted(folder.glob("*.yaml"))
    if not files:
        pytest.skip(f"No hay plantillas en {folder}")
    return {f.name: yaml.load(f.read_text(encoding="utf-8"), Loader=_CfnLoader) for f in files}


@pytest.fixture(scope="session")
def resources(templates):
    """Lista de (archivo, nombre_logico, definicion) de todos los recursos."""
    return [
        (fname, name, res)
        for fname, t in templates.items()
        for name, res in (t.get("Resources") or {}).items()
    ]


def dump(obj):
    return json.dumps(obj, default=str)
