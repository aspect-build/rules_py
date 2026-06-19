import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def _write_member(archive: zipfile.ZipFile, name: str, data: bytes, mode: int) -> None:
    info = zipfile.ZipInfo(name)
    info.external_attr = mode << 16
    archive.writestr(info, data)


def _build_wheel(path: Path, *, broken: bool) -> None:
    body = b"def f(\n" if broken else b"def f():\n    return 1\n"
    with zipfile.ZipFile(path, "w") as archive:
        _write_member(archive, "fixture/__init__.py", b"VALUE = 1\n", 0o644)
        _write_member(archive, "fixture/mod.py", body, 0o644)
        _write_member(archive, "fixture-1.0.dist-info/RECORD", b"", 0o644)

def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


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

        bad_wheel = root / "broken-1.0-py3-none-any.whl"
        _build_wheel(bad_wheel, broken=True)
        bad_out = root / "bad"
        bad = _run_unpack(unpack, bad_wheel, bad_out)
        assert bad.returncode != 0, "expected non-zero exit on compile failure"
        assert "compileall failed" in bad.stderr, bad.stderr

        wheel = root / "fixture-1.0-py3-none-any.whl"
        with zipfile.ZipFile(wheel, "w") as archive:
            _write_member(archive, "fixture/__init__.py", b"VALUE = 1\n", 0o600)
            _write_member(archive, "fixture/executable", b"payload\n", 0o700)
            _write_member(
                archive,
                "fixture-1.0.data/scripts/wheel-tool",
                b"#!/usr/bin/python\nprint('tool')\n",
                0o600,
            )
            _write_member(
                archive,
                "fixture-1.0.dist-info/entry_points.txt",
                b"[console_scripts]\nfixture-cli = fixture:main\n",
                0o600,
            )
            _write_member(archive, "fixture-1.0.dist-info/RECORD", b"", 0o600)

        for inherited_umask in (0o077, 0o000):
            output = root / f"install-{inherited_umask:o}"
            output.mkdir(mode=0o700)
            wrapper = (
                "import os, runpy, sys; "
                f"os.umask({inherited_umask}); "
                "script = sys.argv[1]; "
                "sys.argv = sys.argv[1:]; "
                "runpy.run_path(script, run_name='__main__')"
            )
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    wrapper,
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
                check=True,
            )

            site_packages = (
                output
                / "lib"
                / f"python{sys.version_info.major}.{sys.version_info.minor}"
                / "site-packages"
            )
            dist_info = site_packages / "fixture-1.0.dist-info"
            pyc = next((site_packages / "fixture" / "__pycache__").glob("*.pyc"))

            for directory in (
                output / "lib",
                site_packages.parent,
                site_packages,
                site_packages / "fixture",
                dist_info,
                pyc.parent,
                output / "bin",
            ):
                assert _mode(directory) == 0o755
            assert _mode(site_packages / "fixture" / "__init__.py") == 0o644
            assert _mode(site_packages / "fixture" / "executable") == 0o755
            assert _mode(output / "bin" / "wheel-tool") == 0o755
            assert _mode(output / "bin" / "fixture-cli") == 0o755
            assert _mode(dist_info / "INSTALLER") == 0o644
            assert _mode(dist_info / "REQUESTED") == 0o644
            assert _mode(dist_info / "RECORD") == 0o644
            assert _mode(pyc) == 0o644


if __name__ == "__main__":
    main()
