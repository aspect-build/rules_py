import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile
from base64 import urlsafe_b64encode
from pathlib import Path
from typing import Optional


def _write_member(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name)
    info.external_attr = 0o644 << 16
    archive.writestr(info, data)


def _write_wheel(path: Path, distribution: str, members: dict[str, bytes]) -> None:
    dist_info = f"{distribution}-1.0.dist-info"
    members = dict(members)
    members[f"{dist_info}/METADATA"] = (
        "Metadata-Version: 2.1\n"
        f"Name: {distribution.replace('_', '-')}\n"
        "Version: 1.0\n"
    ).encode()
    members[f"{dist_info}/WHEEL"] = (
        "Wheel-Version: 1.0\n"
        "Generator: rules_py test\n"
        "Root-Is-Purelib: true\n"
        "Tag: py3-none-any\n"
    ).encode()
    record_path = f"{dist_info}/RECORD"
    record = []
    for name, data in sorted(members.items()):
        digest = urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("=")
        record.append(f"{name},sha256={digest},{len(data)}")
    record.append(f"{record_path},,")
    members[record_path] = ("\n".join(record) + "\n").encode()

    with zipfile.ZipFile(path, "w") as archive:
        for name, data in members.items():
            _write_member(archive, name, data)


def _build_wheel(path: Path, *, broken: bool) -> None:
    body = b"def f(\n" if broken else b"def f():\n    return 1\n"
    _write_wheel(path, "fixture", {
        "fixture/__init__.py": b"VALUE = 1\n",
        "fixture/mod.py": body,
    })


def _run_unpack(
    unpack: Path,
    wheel: Path,
    output: Path,
    expected_metadata: Optional[dict[str, object]] = None,
    expected_metadata_origin: Optional[str] = None,
    patch: Optional[Path] = None,
) -> subprocess.CompletedProcess:
    command = [
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
    ]
    if expected_metadata is not None:
        command.extend(["--expected-metadata", json.dumps(expected_metadata)])
    if expected_metadata_origin is not None:
        command.extend(["--expected-metadata-origin", expected_metadata_origin])
    if patch is not None:
        command.extend(["--patch", str(patch), "--patch-strip", "1"])
    return subprocess.run(
        command,
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

        entry_point_wheel = root / "entry_point-1.0-py3-none-any.whl"
        _write_wheel(
            entry_point_wheel,
            "entry_point",
            {
                "fixture/__init__.py": b"class Commands:\n"
                b"    @staticmethod\n"
                b"    def main():\n"
                b"        return 0\n",
                "entry_point-1.0.dist-info/entry_points.txt": (
                    b"[console_scripts]\n"
                    b"Fixture-Cli = fixture:Commands.main [extra]\n"
                ),
            },
        )

        entry_point_out = root / "entry-point"
        entry_point = _run_unpack(
            unpack,
            entry_point_wheel,
            entry_point_out,
        )
        assert entry_point.returncode == 0, entry_point.stderr
        assert {entry.name for entry in (entry_point_out / "bin").iterdir()} == {
            "Fixture-Cli",
        }, "console-script name was not preserved"
        script = entry_point_out / "bin" / "Fixture-Cli"
        site_packages = (
            entry_point_out
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        subprocess.run(
            [sys.executable, str(script)],
            check=True,
            env={"PYTHONPATH": str(site_packages)},
        )

        metadata = {
            "console_scripts": ["Fixture-Cli=fixture:Commands.main"],
            "top_levels": {
                "entry_point-1.0.dist-info": "directory",
                "fixture": "directory",
            },
        }
        matching = _run_unpack(
            unpack,
            entry_point_wheel,
            root / "matching-metadata",
            expected_metadata=metadata,
        )
        assert matching.returncode == 0, matching.stderr

        layout_only = _run_unpack(
            unpack,
            entry_point_wheel,
            root / "unknown-scripts",
            expected_metadata={"top_levels": metadata["top_levels"]},
        )
        assert layout_only.returncode == 0, layout_only.stderr

        known_empty_scripts = _run_unpack(
            unpack,
            entry_point_wheel,
            root / "known-empty-scripts",
            expected_metadata={"console_scripts": []},
            expected_metadata_origin="uv.built_wheel_metadata()",
        )
        assert known_empty_scripts.returncode != 0
        assert "uv.built_wheel_metadata()" in known_empty_scripts.stderr
        assert "expected " in known_empty_scripts.stderr
        assert "actual " in known_empty_scripts.stderr

        patch = root / "add-top-level.patch"
        site_packages_rel = (
            f"lib/python{sys.version_info.major}.{sys.version_info.minor}"
            "/site-packages/added.py"
        )
        patch.write_text(
            "--- /dev/null\n"
            f"+++ b/{site_packages_rel}\n"
            "@@ -0,0 +1 @@\n"
            "+VALUE = 1\n"
        )
        changed_layout = _run_unpack(
            unpack,
            entry_point_wheel,
            root / "changed-layout",
            expected_metadata=metadata,
            patch=patch,
        )
        assert changed_layout.returncode != 0
        assert "Installed wheel metadata did not match repository analysis" in (
            changed_layout.stderr
        )
        assert "expected " in changed_layout.stderr
        assert "actual " in changed_layout.stderr

        namespace_wheel = root / "namespace-1.0-py3-none-any.whl"
        _write_wheel(
            namespace_wheel,
            "namespace",
            {"namespace_pkg/module.py": b"VALUE = 1\n"},
        )
        namespace_metadata = {"namespace_top_levels": ["namespace_pkg"]}
        namespace_ok = _run_unpack(
            unpack,
            namespace_wheel,
            root / "namespace",
            expected_metadata=namespace_metadata,
        )
        assert namespace_ok.returncode == 0, namespace_ok.stderr

        namespace_patch = root / "make-namespace-regular.patch"
        namespace_init_rel = (
            f"lib/python{sys.version_info.major}.{sys.version_info.minor}"
            "/site-packages/namespace_pkg/__init__.py"
        )
        namespace_patch.write_text(
            "--- /dev/null\n"
            f"+++ b/{namespace_init_rel}\n"
            "@@ -0,0 +1 @@\n"
            "+# regular package\n"
        )
        changed_namespace = _run_unpack(
            unpack,
            namespace_wheel,
            root / "changed-namespace",
            expected_metadata=namespace_metadata,
            expected_metadata_origin="uv.built_wheel_metadata()",
            patch=namespace_patch,
        )
        assert changed_namespace.returncode != 0
        assert "uv.built_wheel_metadata()" in changed_namespace.stderr
        assert '"namespace_top_levels": []' in changed_namespace.stderr


if __name__ == "__main__":
    main()
