"""Create deterministic local-source fixtures without checking in binary blobs."""

from __future__ import annotations

import base64
import csv
import gzip
import hashlib
import io
import json
import re
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _write_wheel(artifacts: Path) -> Path:
    wheel = artifacts / "local_wheel-1.0.0-py3-none-any.whl"
    metadata = "local_wheel-1.0.0.dist-info"
    entries = {
        "local_wheel/__init__.py": b'SOURCE_KIND = "local wheel"\n',
        f"{metadata}/METADATA": (
            b"Metadata-Version: 2.3\n"
            b"Name: local-wheel\n"
            b"Version: 1.0.0\n"
            b"Requires-Python: >=3.11\n"
        ),
        f"{metadata}/WHEEL": (
            b"Wheel-Version: 1.0\n"
            b"Generator: rules_py local-source fixture\n"
            b"Root-Is-Purelib: true\n"
            b"Tag: py3-none-any\n"
        ),
    }
    records = io.StringIO(newline="")
    writer = csv.writer(records, lineterminator="\n")
    for name, data in entries.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest())
        writer.writerow((name, "sha256=" + digest.decode().rstrip("="), len(data)))
    record_name = f"{metadata}/RECORD"
    writer.writerow((record_name, "", ""))
    entries[record_name] = records.getvalue().encode()

    with zipfile.ZipFile(wheel, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    return wheel


def _write_sdist(artifacts: Path) -> Path:
    sdist = artifacts / "local_sdist-1.0.0.tar.gz"
    root = "local_sdist-1.0.0"
    entries = {
        f"{root}/PKG-INFO": (
            b"Metadata-Version: 2.3\n"
            b"Name: local-sdist\n"
            b"Version: 1.0.0\n"
            b"Requires-Python: >=3.11\n"
        ),
        f"{root}/pyproject.toml": (
            b"[build-system]\n"
            b'requires = ["setuptools>=80"]\n'
            b'build-backend = "setuptools.build_meta"\n'
            b"\n"
            b"[project]\n"
            b'name = "local-sdist"\n'
            b'version = "1.0.0"\n'
            b'requires-python = ">=3.11"\n'
        ),
        f"{root}/src/local_sdist/__init__.py": (
            b'SOURCE_KIND = "local source archive"\n'
        ),
    }
    with sdist.open("wb") as output:
        with gzip.GzipFile(
            filename="", fileobj=output, mode="wb", mtime=0
        ) as gzip_file:
            with tarfile.open(fileobj=gzip_file, mode="w") as archive:
                for name, data in entries.items():
                    info = tarfile.TarInfo(name)
                    info.mode = 0o644
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
    return sdist


def _assert_locked_hash(lockfile: Path, name: str, artifact: Path) -> None:
    lock = lockfile.read_text()
    package = re.search(
        rf'(?ms)^\[\[package\]\]\nname = "{re.escape(name)}"\n.*?(?=^\[\[package\]\]|\Z)',
        lock,
    )
    if package is None:
        raise ValueError(f"{name} is missing from {lockfile}")
    expected = re.search(r'hash = "sha256:([0-9a-f]{64})"', package.group())
    actual = _sha256(artifact.read_bytes())
    print(f"{artifact.name}: sha256:{actual}", flush=True)
    if expected is None or expected.group(1) != actual:
        raise ValueError(f"{artifact.name} does not match its uv.lock hash")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate_artifacts.py WORKSPACE RULES_PY_ROOT")

    fixture = Path(__file__).resolve().parent
    workspace = Path(sys.argv[1]).resolve()
    rules_py_root = Path(sys.argv[2]).resolve()
    workspace.mkdir(parents=True, exist_ok=True)

    for name in (
        "pyproject.toml",
        "uv.lock",
        "__test__.py",
        "expected_sdist.BUILD.bazel",
    ):
        shutil.copyfile(fixture / name, workspace / name)

    shutil.copyfile(rules_py_root / ".bazelversion", workspace / ".bazelversion")
    shutil.copyfile(fixture / "BUILD.bazel.template", workspace / "BUILD.bazel")
    module = (fixture / "MODULE.bazel.template").read_text()
    module = module.replace("__ASPECT_RULES_PY_ROOT__", json.dumps(str(rules_py_root)))
    (workspace / "MODULE.bazel").write_text(module)

    directory = Path("packages/local;directory")
    for name in ("BUILD.bazel", "pyproject.toml", "src/local_directory/__init__.py"):
        destination = workspace / directory / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture / directory / name, destination)

    # Module extensions resolve these local paths before Bazel can execute a
    # genrule. Generate both archives only in this temporary workspace to keep
    # real uv.lock coverage without committing blobs or creating egg-info.
    artifacts = workspace / "artifacts"
    artifacts.mkdir()
    for name, artifact in (
        ("local-wheel", _write_wheel(artifacts)),
        ("local-sdist", _write_sdist(artifacts)),
    ):
        _assert_locked_hash(workspace / "uv.lock", name, artifact)


if __name__ == "__main__":
    main()
