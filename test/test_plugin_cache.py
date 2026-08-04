# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

from pathlib import Path

import pytest

from scripts.ci.plugin_cache import calculate_cache_key


@pytest.fixture
def cache_inputs(tmp_path: Path) -> tuple[Path, Path]:
    source_root = tmp_path / "source"
    engine_root = tmp_path / "engine"
    (source_root / "src" / "unreal_plugin" / "Source").mkdir(parents=True)
    (source_root / "scripts").mkdir()
    (engine_root / "Engine" / "Build").mkdir(parents=True)
    (source_root / "src" / "unreal_plugin" / "plugin.uplugin").write_text(
        '{"FileVersion": 3}', encoding="utf-8"
    )
    (source_root / "src" / "unreal_plugin" / "Source" / "Plugin.cpp").write_text(
        "void BuildPlugin() {}", encoding="utf-8"
    )
    (source_root / "scripts" / "build_plugin.py").write_text(
        "def build(): pass", encoding="utf-8"
    )
    (engine_root / "Engine" / "Build" / "Build.version").write_text(
        '{"MajorVersion": 5, "MinorVersion": 6}', encoding="utf-8"
    )
    return source_root, engine_root


def test_cache_key_is_deterministic(cache_inputs: tuple[Path, Path]) -> None:
    source_root, engine_root = cache_inputs

    first = calculate_cache_key(source_root, engine_root, "5.6")
    second = calculate_cache_key(source_root, engine_root, "5.6")

    assert first == second
    assert len(first) == 64


@pytest.mark.parametrize(
    ("relative_path", "new_content"),
    [
        ("src/unreal_plugin/Source/Plugin.cpp", "void Changed() {}"),
        ("scripts/build_plugin.py", "def changed(): pass"),
    ],
)
def test_cache_key_changes_for_build_input(
    cache_inputs: tuple[Path, Path], relative_path: str, new_content: str
) -> None:
    source_root, engine_root = cache_inputs
    original = calculate_cache_key(source_root, engine_root, "5.6")

    (source_root / relative_path).write_text(new_content, encoding="utf-8")

    assert calculate_cache_key(source_root, engine_root, "5.6") != original


def test_cache_key_changes_for_engine_identity(cache_inputs: tuple[Path, Path]) -> None:
    source_root, engine_root = cache_inputs
    original = calculate_cache_key(source_root, engine_root, "5.6")

    (engine_root / "Engine" / "Build" / "Build.version").write_text(
        '{"MajorVersion": 5, "MinorVersion": 6, "Changelist": 1}', encoding="utf-8"
    )

    assert calculate_cache_key(source_root, engine_root, "5.6") != original
