import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def _write_member(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name)
    info.external_attr = 0o644 << 16
    archive.writestr(info, data)


def _build_wheel(path: Path, *, legacy_syntax: bool) -> None:
    body = (
        b"raise RuntimeError, None, None\n"
        if legacy_syntax
        else b"def f():\n    return 1\n"
    )
    with zipfile.ZipFile(path, "w") as archive:
        _write_member(archive, "fixture/__init__.py", b"VALUE = 1\n")
        _write_member(archive, "fixture/mod.py", body)
        _write_member(archive, "fixture-1.0.dist-info/RECORD", b"")


def _run_unpack(
    unpack: Path,
    wheel: Path,
    output: Path,
    python: Path,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable,
            str(unpack),
            "--into",
            str(output),
            "--wheel",
            str(wheel),
            "--python-version-major",
            str(sys.version_info.major),
            "--python-version-minor",
            str(sys.version_info.minor),
            "--compile-pyc",
            "--python",
            str(python),
        ],
        capture_output=True,
        text=True,
    )


def main() -> None:
    unpack = Path(sys.argv[1])
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)

        # A wheel that compiles cleanly installs successfully (exit 0) and
        # produces bytecode.
        good_wheel = root / "fixture-1.0-py3-none-any.whl"
        _build_wheel(good_wheel, legacy_syntax=False)
        good_out = root / "good"
        ok = _run_unpack(unpack, good_wheel, good_out, Path(sys.executable))
        assert ok.returncode == 0, ok.stderr
        site_packages = (
            good_out
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        assert next((site_packages / "fixture" / "__pycache__").glob("*.pyc"))

        # Wheels may retain source for older interpreters. Compatible modules
        # still compile, while the incompatible file remains diagnostic.
        legacy_wheel = root / "legacy-1.0-py3-none-any.whl"
        _build_wheel(legacy_wheel, legacy_syntax=True)
        legacy_out = root / "legacy"
        legacy = _run_unpack(
            unpack,
            legacy_wheel,
            legacy_out,
            Path(sys.executable),
        )
        assert legacy.returncode == 0, legacy.stderr
        legacy_site_packages = (
            legacy_out
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        assert next(
            (legacy_site_packages / "fixture" / "__pycache__").glob("__init__*.pyc")
        )
        assert "SyntaxError" in legacy.stdout + legacy.stderr

        false = shutil.which("false")
        assert false is not None, "test host has no false executable"
        failed = _run_unpack(
            unpack,
            good_wheel,
            root / "failed-interpreter",
            Path(false),
        )
        assert failed.returncode != 0, "expected child interpreter failure"
        assert "CalledProcessError" in failed.stderr


if __name__ == "__main__":
    main()
