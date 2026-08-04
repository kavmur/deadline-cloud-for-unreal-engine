# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

"""Create cache keys and install packaged Unreal plugin builds in CI."""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from pathlib import Path


CACHE_SCHEMA = "unreal-plugin-build-v1"
PLUGIN_FOLDER_NAME = "UnrealDeadlineCloudService"


def _hash_file(hasher: "hashlib._Hash", root: Path, path: Path) -> None:
    relative_path = path.relative_to(root).as_posix().encode("utf-8")
    hasher.update(len(relative_path).to_bytes(8, "big"))
    hasher.update(relative_path)
    with path.open("rb") as file_handle:
        while chunk := file_handle.read(1024 * 1024):
            hasher.update(len(chunk).to_bytes(8, "big"))
            hasher.update(chunk)


def calculate_cache_key(source_root: Path, engine_root: Path, ue_version: str) -> str:
    """Hash all binary build inputs using stable, normalized paths."""

    plugin_root = source_root / "src" / "unreal_plugin"
    build_script = source_root / "scripts" / "build_plugin.py"
    engine_version = engine_root / "Engine" / "Build" / "Build.version"

    if not plugin_root.is_dir():
        raise FileNotFoundError(f"Plugin source directory was not found: {plugin_root}")
    for required_file in (build_script, engine_version):
        if not required_file.is_file():
            raise FileNotFoundError(f"Cache identity file was not found: {required_file}")

    hasher = hashlib.sha256()
    hasher.update(CACHE_SCHEMA.encode("ascii"))
    hasher.update(b"\0")
    hasher.update(ue_version.encode("ascii"))

    plugin_files = sorted(
        (path for path in plugin_root.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(source_root).as_posix(),
    )
    for path in (*plugin_files, build_script):
        _hash_file(hasher, source_root, path)

    _hash_file(hasher, engine_root, engine_version)
    return hasher.hexdigest()


def install_cached_plugin(source_root: Path, engine_root: Path, package_root: Path) -> None:
    """Install cached native output with the current Python wheel and test data."""

    required_paths = (
        package_root / "Binaries",
        package_root / "Resources",
        package_root / "Content",
        package_root / f"{PLUGIN_FOLDER_NAME}.uplugin",
    )
    missing = [str(path) for path in required_paths if not path.exists()]
    if missing:
        raise FileNotFoundError(f"Cached plugin package is incomplete: {', '.join(missing)}")

    sys.path.insert(0, os.fspath(source_root))
    from scripts.build_plugin import (  # pylint: disable=import-outside-toplevel
        build_whl,
        get_plugin_folder,
        install_plugin,
        install_test_content,
    )

    wheel_path = build_whl()
    install_plugin(os.fspath(engine_root), os.fspath(package_root), wheel_path, binaries=True)
    install_test_content(get_plugin_folder(os.fspath(engine_root)))


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    key_parser = subparsers.add_parser("key")
    key_parser.add_argument("--source-root", type=Path, required=True)
    key_parser.add_argument("--engine-root", type=Path, required=True)
    key_parser.add_argument("--ue-version", required=True)

    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--source-root", type=Path, required=True)
    install_parser.add_argument("--engine-root", type=Path, required=True)
    install_parser.add_argument("--package-root", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "key":
        print(calculate_cache_key(args.source_root, args.engine_root, args.ue_version))
    else:
        install_cached_plugin(args.source_root, args.engine_root, args.package_root)


if __name__ == "__main__":
    main()
