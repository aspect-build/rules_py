import json
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


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def main() -> None:
    unpack = Path(sys.argv[1])
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        wheel = root / "fixture-1.0-py3-none-any.whl"
        with zipfile.ZipFile(wheel, "w") as archive:
            _write_member(
                archive,
                "fixture/__init__.py",
                b"class commands:\n    @staticmethod\n    def main():\n        return 0\n",
                0o600,
            )
            _write_member(archive, "root_module.py", b"VALUE = 1\n", 0o600)
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
                b"[console_scripts]\nfixture-cli = fixture:commands.main\n",
                0o600,
            )
            _write_member(archive, "fixture-1.0.dist-info/RECORD", b"", 0o600)

        metadata = {
            "console_scripts": ["fixture-cli=fixture:commands.main"],
            "top_levels": {
                "fixture": "directory",
                "fixture-1.0.dist-info": "directory",
                "root_module.py": "file",
            },
        }
        expected_metadata = json.dumps(metadata, sort_keys=True)
        compiled_metadata = json.loads(expected_metadata)
        compiled_metadata["top_levels"]["__pycache__"] = "directory"
        compiled_metadata = json.dumps(compiled_metadata, sort_keys=True)

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
                    "--expected-metadata",
                    compiled_metadata,
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
            root_pyc = next((site_packages / "__pycache__").glob("root_module*.pyc"))

            for directory in (
                output / "lib",
                site_packages.parent,
                site_packages,
                site_packages / "fixture",
                dist_info,
                pyc.parent,
                root_pyc.parent,
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
            assert _mode(root_pyc) == 0o644
            subprocess.run(
                [sys.executable, str(output / "bin" / "fixture-cli")],
                check=True,
                env={"PYTHONPATH": str(site_packages)},
            )

        patch = root / "add-entry-point.patch"
        entry_points_rel = (
            f"lib/python{sys.version_info.major}.{sys.version_info.minor}"
            "/site-packages/fixture-1.0.dist-info/entry_points.txt"
        )
        patch.write_text(
            f"--- a/{entry_points_rel}\n"
            f"+++ b/{entry_points_rel}\n"
            "@@ -1,2 +1,3 @@\n"
            " [console_scripts]\n"
            " fixture-cli = fixture:commands.main\n"
            "+added-cli = fixture:commands.main\n"
        )
        changed = subprocess.run(
            [
                sys.executable,
                str(unpack),
                "--into",
                str(root / "changed-install"),
                "--wheel",
                str(wheel),
                "--python-version-major",
                str(sys.version_info.major),
                "--python-version-minor",
                str(sys.version_info.minor),
                "--expected-metadata",
                expected_metadata,
                "--patch",
                str(patch),
                "--patch-strip",
                "1",
            ],
            capture_output=True,
            text=True,
        )
        assert changed.returncode != 0
        assert "Installed wheel metadata changed" in changed.stderr, (
            changed.stdout + changed.stderr
        )

        offset_patch = root / "offset.patch"
        package_rel = (
            f"lib/python{sys.version_info.major}.{sys.version_info.minor}"
            "/site-packages/fixture/__init__.py"
        )
        offset_patch.write_text(
            f"--- a/{package_rel}\n"
            f"+++ b/{package_rel}\n"
            "@@ -3,4 +3,4 @@\n"
            " class commands:\n"
            "     @staticmethod\n"
            "     def main():\n"
            "-        return 0\n"
            "+        return 1\n"
        )
        offset_output = root / "offset-install"
        subprocess.run(
            [
                sys.executable,
                str(unpack),
                "--into",
                str(offset_output),
                "--wheel",
                str(wheel),
                "--python-version-major",
                str(sys.version_info.major),
                "--python-version-minor",
                str(sys.version_info.minor),
                "--expected-metadata",
                expected_metadata,
                "--patch",
                str(offset_patch),
                "--patch-strip",
                "1",
            ],
            check=True,
        )
        offset_package = (
            offset_output
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
            / "fixture"
        )
        assert "return 1" in (offset_package / "__init__.py").read_text()
        assert {path.name for path in offset_package.iterdir()} == {
            "__init__.py",
            "executable",
        }

        unknown_scripts = subprocess.run(
            [
                sys.executable,
                str(unpack),
                "--into",
                str(root / "unknown-install"),
                "--wheel",
                str(wheel),
                "--python-version-major",
                str(sys.version_info.major),
                "--python-version-minor",
                str(sys.version_info.minor),
                "--metadata-unavailable",
            ],
            capture_output=True,
            text=True,
        )
        assert unknown_scripts.returncode != 0
        assert "Source-built wheels with console scripts are unsupported" in (
            unknown_scripts.stderr
        )


if __name__ == "__main__":
    main()
