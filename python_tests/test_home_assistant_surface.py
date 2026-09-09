"""Static and pure-policy checks for the HACS integration boundary."""

from __future__ import annotations

import ast
import importlib.util
import json
import tomllib
from pathlib import Path
from types import SimpleNamespace

_ROOT = Path(__file__).resolve().parents[1]
_INTEGRATION = _ROOT / "custom_components" / "openquii"


def test_manifest_and_packaging_share_one_canonical_core() -> None:
    manifest = json.loads((_INTEGRATION / "manifest.json").read_text())
    pyproject = tomllib.loads((_ROOT / "pyproject.toml").read_text())

    assert manifest["domain"] == "openquii"
    assert manifest["config_flow"] is True
    assert manifest["iot_class"] == "local_polling"
    assert manifest["requirements"] == []
    assert manifest["version"] == "0.2.2"
    assert pyproject["project"]["version"] == "0.2.2"
    assert '__version__ = "0.2.2"' in (_INTEGRATION / "core" / "__init__.py").read_text()
    assert 'public static let version = "0.2.2"' in (
        _ROOT / "Sources" / "OpenQUII" / "OpenQUII.swift"
    ).read_text()
    assert pyproject["tool"]["setuptools"]["package-dir"]["openquii"] == (
        "custom_components/openquii/core"
    )


def test_base_strings_and_english_translation_match() -> None:
    strings = json.loads((_INTEGRATION / "strings.json").read_text())
    translation = json.loads((_INTEGRATION / "translations" / "en.json").read_text())
    assert strings == translation


def test_only_button_module_can_reference_open_door() -> None:
    references: dict[str, int] = {}
    for path in _INTEGRATION.glob("*.py"):
        count = path.read_text().count("open_door")
        if count:
            references[path.name] = count
    assert references == {"button.py": 1}


def test_button_checks_user_context_before_exactly_one_open_call() -> None:
    source = (_INTEGRATION / "button.py").read_text()
    tree = ast.parse(source)
    method = next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "async_press"
    )
    checks = [
        node
        for node in ast.walk(method)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "is_authenticated_user_action"
    ]
    human_checks = [
        node
        for node in ast.walk(method)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "is_authenticated_human_user"
    ]
    auth_lookups = [
        node
        for node in ast.walk(method)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "async_get_user"
    ]
    open_calls = [
        node
        for node in ast.walk(method)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "open_door"
    ]
    assert len(checks) == 1
    assert len(human_checks) == 1
    assert len(auth_lookups) == 1
    assert len(open_calls) == 1
    assert (
        checks[0].lineno
        < auth_lookups[0].lineno
        < human_checks[0].lineno
        < open_calls[0].lineno
    )


def test_pure_user_action_policy_rejects_automation_context() -> None:
    path = _INTEGRATION / "control_policy.py"
    spec = importlib.util.spec_from_file_location("openquii_control_policy", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert module.is_authenticated_user_action("authenticated-user") is True
    assert module.is_authenticated_user_action(None) is False
    assert module.is_authenticated_user_action("") is False
    assert module.is_authenticated_user_action("   ") is False


def test_pure_user_policy_requires_active_non_system_human() -> None:
    path = _INTEGRATION / "control_policy.py"
    spec = importlib.util.spec_from_file_location("openquii_control_policy_user", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert module.is_authenticated_human_user(
        SimpleNamespace(is_active=True, system_generated=False)
    ) is True
    assert module.is_authenticated_human_user(
        SimpleNamespace(is_active=False, system_generated=False)
    ) is False
    assert module.is_authenticated_human_user(
        SimpleNamespace(is_active=True, system_generated=True)
    ) is False
    assert module.is_authenticated_human_user(None) is False


def test_setup_polling_and_config_flow_never_reference_actuation() -> None:
    for name in ("__init__.py", "config_flow.py", "coordinator.py", "diagnostics.py"):
        assert "open_door" not in (_INTEGRATION / name).read_text()


def test_unlock_credential_mode_is_explicit_and_never_inferred_by_shape() -> None:
    flow = (_INTEGRATION / "config_flow.py").read_text()
    button = (_INTEGRATION / "button.py").read_text()

    assert "VERSION = 2" in flow
    assert "CONF_UNLOCK_CREDENTIAL_MODE" in flow
    assert "UnlockPassword(user_input[CONF_UNLOCK_PASSWORD])" in flow
    assert "UnlockPasswordDigest(user_input[CONF_UNLOCK_PASSWORD])" in flow
    assert "len(" not in flow
    assert "fullmatch" not in flow

    assert "UnlockPassword(unlock_value)" in button
    assert "UnlockPasswordDigest(unlock_value)" in button
    assert "UNLOCK_CREDENTIAL_MODE_PLAINTEXT" in button
    assert "UNLOCK_CREDENTIAL_MODE_SHA256_DIGEST" in button


def test_v1_migration_preserves_legacy_plaintext_semantics() -> None:
    source = (_INTEGRATION / "__init__.py").read_text()
    assert "if entry.version == 1:" in source
    assert "data[CONF_UNLOCK_CREDENTIAL_MODE] = UNLOCK_CREDENTIAL_MODE_PLAINTEXT" in source
    assert "async_update_entry(entry, data=data, version=2)" in source
