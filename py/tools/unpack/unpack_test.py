import hashlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from base64 import urlsafe_b64encode
from pathlib import Path


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


def _build_wheel(path: Path, *, legacy_syntax: bool) -> None:
    body = (
        b"raise RuntimeError, None, None\n"
        if legacy_syntax
        else b"def f():\n    return 1\n"
    )
    _write_wheel(
        path,
        "fixture",
        {
            "fixture/__init__.py": b"VALUE = 1\n",
            "fixture/mod.py": body,
        },
    )


def _run_unpack(
    unpack: Path,
    wheel: Path,
    output: Path,
    python: Path,
    extra_args: tuple[str, ...] = (),
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
        str(python),
        *extra_args,
    ]
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

        site_packages_relative = (
            f"lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages"
        )
        namespace_wheel = root / "namespace_fixture-1.0-py3-none-any.whl"
        _write_wheel(
            namespace_wheel,
            "namespace_fixture",
            {"fixture_ns/mod.py": b"VALUE = 1\n"},
        )
        add_init_patch = root / "add-init.patch"
        add_init_patch.write_text(
            f"""\
--- /dev/null
+++ b/{site_packages_relative}/fixture_ns/__init__.py
@@ -0,0 +1 @@
+VALUE = 1
"""
        )
        reclassified = _run_unpack(
            unpack,
            namespace_wheel,
            root / "reclassified-layout",
            Path(sys.executable),
            (
                "--patch",
                str(add_init_patch),
                "--patch-strip",
                "1",
                "--preserve-path",
                "fixture_ns",
            ),
        )
        assert reclassified.returncode != 0, reclassified.stdout + reclassified.stderr
        assert "changed observed package classification: fixture_ns" in reclassified.stderr

        # BSD and GNU patch differ in whether a deletion diff removes the empty
        # file. Use a controlled patch executable for topology transitions that
        # must behave identically on every test host.
        mutation_tool = root / "mutate_tree.py"
        mutation_tool.write_text(
            f"""#!{sys.executable}
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[sys.argv.index("-d") + 1])
operation, relative = sys.stdin.read().splitlines()
target = root / relative
if operation == "unlink":
    target.unlink()
elif operation == "file-to-directory":
    target.unlink()
    target.mkdir()
elif operation == "directory-to-file":
    shutil.rmtree(target)
    target.write_text("replacement\\n")
else:
    raise SystemExit(f"unknown operation: {{operation}}")
"""
        )
        mutation_tool.chmod(0o755)
        for name, operation, changed_path, preserved_path, expected_error in [
            (
                "removed-file",
                "unlink",
                "fixture/mod.py",
                "fixture/mod.py",
                "changed observed wheel file: fixture/mod.py",
            ),
            (
                "file-to-directory",
                "file-to-directory",
                "fixture/mod.py",
                "fixture/mod.py",
                "changed observed wheel file: fixture/mod.py",
            ),
            (
                "regular-to-namespace",
                "unlink",
                "fixture/__init__.py",
                "fixture",
                "changed observed package classification: fixture",
            ),
            (
                "directory-to-file",
                "directory-to-file",
                "fixture",
                "fixture",
                "changed observed wheel directory: fixture",
            ),
        ]:
            mutation = root / f"{name}.patch"
            mutation.write_text(
                f"{operation}\n{site_packages_relative}/{changed_path}\n"
            )
            rejected = _run_unpack(
                unpack,
                good_wheel,
                root / name,
                Path(sys.executable),
                (
                    "--patch",
                    str(mutation),
                    "--patch-tool",
                    str(mutation_tool),
                    "--preserve-path",
                    preserved_path,
                ),
            )
            assert rejected.returncode != 0, rejected.stdout + rejected.stderr
            assert expected_error in rejected.stderr

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
            Path(sys.executable),
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


if __name__ == "__main__":
    main()
