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

        # Members larger than the streaming copy buffer round-trip byte-for-byte.
        large_payload = b"rules_py" * (256 * 1024 + 1)
        assert len(large_payload) > 1024 * 1024
        large_wheel = root / "large_fixture-1.0-py3-none-any.whl"
        _write_wheel(large_wheel, "large_fixture", {"fixture/big.bin": large_payload})
        large_out = root / "large"
        large = _run_unpack(unpack, large_wheel, large_out, Path(sys.executable))
        assert large.returncode == 0, large.stderr
        installed_large = (
            large_out
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
            / "fixture"
            / "big.bin"
        )
        assert installed_large.read_bytes() == large_payload

        # A .data/scripts member with a Python shebang is rewritten to the
        # relocatable launcher and marked executable.
        script_wheel = root / "script_fixture-1.0-py3-none-any.whl"
        _write_wheel(
            script_wheel,
            "script_fixture",
            {"script_fixture-1.0.data/scripts/tool": b"#!/usr/bin/python\nprint('hi')\n"},
        )
        script_out = root / "script"
        script = _run_unpack(unpack, script_wheel, script_out, Path(sys.executable))
        assert script.returncode == 0, script.stderr
        installed_script = script_out / "bin" / "tool"
        assert installed_script.read_bytes() == (
            "#!/bin/sh\n"
            "'''exec' \"$(dirname -- \"$(realpath -- \"$0\")\")\"/'python3' \"$0\" \"$@\"\n"
            "' '''\n"
            "print('hi')\n"
        ).encode()
        assert installed_script.stat().st_mode & 0o111

        for case, member in [
            ("roottraversal", "../../../../escaped.py"),
            ("rootabsolute", str(root / "escaped.py")),
            ("rootdrive", "C:/escaped.py"),
            ("rootnesteddrive", "fixture/D:/escaped.py"),
            ("rootunc", "//server/share/escaped.py"),
            ("rootbackslash", "fixture\\escaped.py"),
            ("roottrailing", "fixture/.. /escaped.py"),
            ("rootreserved", "fixture/NuL .txt/escaped.py"),
            ("rootconin", "fixture/cOnIn$.txt/escaped.py"),
            ("datatraversal", "datatraversal-1.0.data/data/../escaped.py"),
            ("dataabsolute", "dataabsolute-1.0.data/data//escaped.py"),
            ("datadrive", "datadrive-1.0.data/data/C:/escaped.py"),
            ("datanesteddrive", "datanesteddrive-1.0.data/data/fixture/D:/escaped.py"),
            ("dataunc", "dataunc-1.0.data/data///server/share/escaped.py"),
            ("databackslash", "databackslash-1.0.data/data/fixture\\escaped.py"),
            ("datatrailing", "datatrailing-1.0.data/data/.. ./escaped.py"),
            ("datareserved", "datareserved-1.0.data/data/fixture/lPt9.log/escaped.py"),
            ("dataconout", "dataconout-1.0.data/data/fixture/ConOut$.log/escaped.py"),
        ]:
            traversal_wheel = root / f"{case}-1.0-py3-none-any.whl"
            _write_wheel(traversal_wheel, case, {member: b"escaped\n"})
            rejected = _run_unpack(
                unpack,
                traversal_wheel,
                root / f"{case}-out",
                Path(sys.executable),
            )
            assert rejected.returncode != 0, "{} was accepted\n{}{}".format(
                case,
                rejected.stdout,
                rejected.stderr,
            )
            assert "Invalid wheel member path" in rejected.stderr

        site_packages_relative = (
            f"lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages"
        )
        content_patch = root / "content.patch"
        content_patch.write_text(
            f"""\
--- a/{site_packages_relative}/fixture/__init__.py
+++ b/{site_packages_relative}/fixture/__init__.py
@@ -1 +1 @@
-VALUE = 1
+VALUE = 2
--- /dev/null
+++ b/{site_packages_relative}/fixture-1.0.dist-info/__init__.py
@@ -0,0 +1 @@
+# Metadata directories are not import packages.
"""
        )
        content_out = root / "content-edit"
        content_edit = _run_unpack(
            unpack,
            good_wheel,
            content_out,
            Path(sys.executable),
            (
                "--patch",
                str(content_patch),
                "--patch-strip",
                "1",
                "--preserve-path",
                "fixture",
                "--preserve-path",
                "fixture/__init__.py",
                "--preserve-path",
                "fixture-1.0.dist-info",
            ),
        )
        assert content_edit.returncode == 0, content_edit.stdout + content_edit.stderr
        content_site_packages = content_out / site_packages_relative
        assert (content_site_packages / "fixture" / "__init__.py").read_text() == (
            "VALUE = 2\n"
        )
        assert (
            content_site_packages / "fixture-1.0.dist-info" / "__init__.py"
        ).is_file()

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
elif operation == "write-native":
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"native")
else:
    raise SystemExit(f"unknown operation: {{operation}}")
"""
        )
        mutation_tool.chmod(0o755)
        native_wheel = root / "native_fixture-1.0-py3-none-any.whl"
        _write_wheel(
            native_wheel,
            "native_fixture",
            {
                "fixture/__init__.py": b"VALUE = 1\n",
                "fixture/native_extension.so": b"native",
            },
        )
        for name, wheel, operation, changed_path, preserved_path, expected_error in [
            (
                "removed-file",
                good_wheel,
                "unlink",
                "fixture/mod.py",
                "fixture/mod.py",
                "changed observed wheel file: fixture/mod.py",
            ),
            (
                "file-to-directory",
                good_wheel,
                "file-to-directory",
                "fixture/mod.py",
                "fixture/mod.py",
                "changed observed wheel file: fixture/mod.py",
            ),
            (
                "regular-to-namespace",
                good_wheel,
                "unlink",
                "fixture/__init__.py",
                "fixture",
                "changed observed package classification: fixture",
            ),
            (
                "directory-to-file",
                good_wheel,
                "directory-to-file",
                "fixture",
                "fixture",
                "changed observed wheel directory: fixture",
            ),
            (
                "added-native",
                good_wheel,
                "write-native",
                "fixture/native_extension.so",
                "fixture",
                "changed observed native files: fixture",
            ),
            (
                "removed-native",
                native_wheel,
                "unlink",
                "fixture/native_extension.so",
                "fixture",
                "changed observed native files: fixture",
            ),
            (
                "added-nested-native",
                native_wheel,
                "write-native",
                "fixture/nested/new_extension.so",
                "fixture",
                "changed observed native files: fixture",
            ),
        ]:
            mutation = root / f"{name}.patch"
            mutation.write_text(
                f"{operation}\n{site_packages_relative}/{changed_path}\n"
            )
            rejected = _run_unpack(
                unpack,
                wheel,
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
                    b"COM10 = fixture:Commands.main\n"
                    b"LPT0 = fixture:Commands.main\n"
                    b"NULled = fixture:Commands.main\n"
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
            "COM10",
            "Fixture-Cli",
            "LPT0",
            "NULled",
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

        for case, name in [
            ("traversal", "../../entry-point-escaped"),
            ("absolute", "/entry-point-escaped"),
            ("drive", "C:/entry-point-escaped"),
            ("nested-drive", "fixture/D:entry-point-escaped"),
            ("unc", "//server/share/entry-point-escaped"),
            ("backslash", "fixture\\entry-point-escaped"),
            ("nested", "fixture/entry-point-escaped"),
            ("trailing", "entry-point-escaped. "),
            ("reserved", "cOm¹.exe"),
        ]:
            distribution = "entry_point_{}".format(case)
            entry_point_wheel = root / f"{distribution}-1.0-py3-none-any.whl"
            _write_wheel(
                entry_point_wheel,
                distribution,
                {
                    "fixture/__init__.py": b"def main():\n    return 0\n",
                    f"{distribution}-1.0.dist-info/entry_points.txt": (
                        "[console_scripts]\n{} = fixture:main\n".format(name).encode()
                    ),
                },
            )
            rejected_entry_point = _run_unpack(
                unpack,
                entry_point_wheel,
                root / f"entry-point-{case}-out",
                Path(sys.executable),
            )
            assert rejected_entry_point.returncode != 0, (
                "{} was accepted\n{}{}".format(
                    case,
                    rejected_entry_point.stdout,
                    rejected_entry_point.stderr,
                )
            )
            assert "Invalid console script name" in rejected_entry_point.stderr


if __name__ == "__main__":
    main()
