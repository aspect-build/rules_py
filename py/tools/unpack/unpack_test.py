import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def _write_member(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name)
    info.external_attr = 0o644 << 16
    archive.writestr(info, data)


def _build_wheel(path: Path, *, broken: bool) -> None:
    body = b"def f(\n" if broken else b"def f():\n    return 1\n"
    with zipfile.ZipFile(path, "w") as archive:
        _write_member(archive, "fixture/__init__.py", b"VALUE = 1\n")
        _write_member(archive, "fixture/mod.py", body)
        _write_member(archive, "fixture-1.0.dist-info/RECORD", b"")


def _run_unpack(unpack: Path, wheel: Path, output: Path) -> subprocess.CompletedProcess:
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
            sys.executable,
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
        _build_wheel(good_wheel, broken=False)
        good_out = root / "good"
        ok = _run_unpack(unpack, good_wheel, good_out)
        assert ok.returncode == 0, ok.stderr
        site_packages = (
            good_out
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        assert next((site_packages / "fixture" / "__pycache__").glob("*.pyc"))

        # A wheel whose source cannot be byte-compiled must fail loudly rather
        # than emit a partially-compiled tree.
        bad_wheel = root / "broken-1.0-py3-none-any.whl"
        _build_wheel(bad_wheel, broken=True)
        bad_out = root / "bad"
        bad = _run_unpack(unpack, bad_wheel, bad_out)
        assert bad.returncode != 0, "expected non-zero exit on compile failure"
        assert "compileall failed" in bad.stderr, bad.stderr


if __name__ == "__main__":
    main()
