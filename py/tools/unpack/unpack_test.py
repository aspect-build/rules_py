import csv
import hashlib
import importlib.util
import importlib.metadata
import py_compile
import runpy
import shutil
import subprocess
import sys
import tempfile
import zipfile
from base64 import urlsafe_b64encode
from pathlib import Path
from types import ModuleType
from typing import Optional


def _write_member(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name)
    info.external_attr = 0o644 << 16
    archive.writestr(info, data)


def _write_wheel(
    path: Path,
    distribution: str,
    members: dict[str, bytes],
    record_overrides: Optional[dict[str, tuple[str, str]]] = None,
    leading_record_rows: tuple[tuple[str, str, str], ...] = (),
) -> None:
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
    record = [",".join(row) for row in leading_record_rows]
    record_overrides = record_overrides or {}
    for name, data in sorted(members.items()):
        digest = urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("=")
        hash_value, size = record_overrides.get(
            name, (f"sha256={digest}", str(len(data)))
        )
        record.append(f"{name},{hash_value},{size}")
    record.append(f"{record_path},,")
    members[record_path] = ("\n".join(record) + "\n").encode()

    with zipfile.ZipFile(path, "w") as archive:
        for name, data in members.items():
            _write_member(archive, name, data)


def _load_unpack(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("rules_py_unpack_test_module", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _record_rows(site_packages: Path) -> list[tuple[str, str, str]]:
    record_path = next(site_packages.glob("*.dist-info/RECORD"))
    with record_path.open(newline="", encoding="utf-8") as record:
        return list(csv.reader(record))


def _site_packages(output: Path) -> Path:
    return (
        output
        / "lib"
        / f"python{sys.version_info.major}.{sys.version_info.minor}"
        / "site-packages"
    )


def _assert_record_matches_installed_files(site_packages: Path) -> None:
    seen = set()
    for relative, digest, size in _record_rows(site_packages):
        assert relative not in seen, relative
        seen.add(relative)
        if not digest and not size:
            assert relative.endswith(".dist-info/RECORD"), relative
            continue
        path = site_packages / relative
        expected_digest = urlsafe_b64encode(
            hashlib.sha256(path.read_bytes()).digest()
        ).decode().rstrip("=")
        assert digest == f"sha256={expected_digest}", relative
        assert size == str(path.stat().st_size), relative


def _corrupt_member(path: Path, name: str) -> None:
    with zipfile.ZipFile(path) as archive:
        info = archive.getinfo(name)
    data_offset = (
        info.header_offset
        + 30
        + len(info.filename.encode("utf-8"))
        + len(info.extra)
    )
    with path.open("r+b") as stream:
        stream.seek(data_offset)
        original = stream.read(1)
        assert original
        stream.seek(data_offset)
        stream.write(bytes([original[0] ^ 0xFF]))


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
            f"fixture/__pycache__/mod.{sys.implementation.cache_tag}.pyc": (
                b"outdated bytecode\n"
            ),
            "fixture-1.0.data/data/share/supplied.pyc": b"uncompiled bytecode\n",
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

        record_wheel = root / "record_fixture-1.0-py3-none-any.whl"
        _write_wheel(
            record_wheel,
            "record_fixture",
            {
                "fixture/__init__.py": b"VALUE = 1\n",
                "fixture/collision.py": b"VALUE = 1\n",
                "record_fixture-1.0.data/purelib/fixture/collision.py": b"VALUE = 2\n",
                "record_fixture-1.0.data/purelib/fixture/pure.py": b"PURE = 1\n",
                "record_fixture-1.0.data/scripts/plain": b"#!/bin/sh\nexit 0\n",
                "record_fixture-1.0.data/scripts/python-script": (
                    b"#!/usr/bin/env python3\nprint('fixture')\n"
                ),
                "record_fixture-1.0.data/data/share/snapshot.dist-info/INSTALLER": b"snapshot\n",
                "record_fixture-1.0.dist-info/entry_points.txt": (
                    b"[console_scripts]\nfixture-cli = fixture:main\n"
                ),
                "record_fixture-1.0.dist-info/INSTALLER": b"wheel-installer\n",
                "record_fixture-1.0.dist-info/REQUESTED": b"wheel-requested\n",
            },
        )
        record_out = root / "record"
        record_site_packages = _site_packages(record_out)
        unpack_module = _load_unpack(unpack)
        original_sha256 = unpack_module._sha256
        hashed_names = set()

        def recording_sha256(path: Path) -> str:
            hashed_names.add(path.name)
            return original_sha256(path)

        unpack_module._sha256 = recording_sha256
        unpack_module.install_wheel(
            sys.version_info.major,
            sys.version_info.minor,
            record_out,
            record_wheel,
        )
        assert not {"__init__.py", "collision.py", "pure.py", "plain"} & hashed_names
        assert {"python-script", "fixture-cli", "INSTALLER", "REQUESTED"} <= hashed_names
        assert (record_site_packages / "fixture" / "collision.py").read_bytes() == b"VALUE = 2\n"
        assert (
            record_site_packages / "record_fixture-1.0.dist-info" / "INSTALLER"
        ).read_bytes() == b"aspect_rules_py"
        assert (
            record_site_packages / "record_fixture-1.0.dist-info" / "REQUESTED"
        ).read_bytes() == b""
        assert any(
            relative.endswith("snapshot.dist-info/INSTALLER")
            for relative, _, _ in _record_rows(record_site_packages)
        )
        _assert_record_matches_installed_files(record_site_packages)

        for name, digest in [
            ("empty-sha", "sha256="),
            ("invalid-sha", "sha256=not-a-digest"),
            ("noncanonical-sha", "sha256=" + "A" * 42 + "B"),
        ]:
            fallback_wheel = root / f"{name}-1.0-py3-none-any.whl"
            _write_wheel(
                fallback_wheel,
                name,
                {"fixture/__init__.py": b"VALUE = 1\n"},
                {"fixture/__init__.py": (digest, str(len(b"VALUE = 1\n")))},
            )
            fallback_out = root / name
            hashed_names.clear()
            unpack_module.install_wheel(
                sys.version_info.major,
                sys.version_info.minor,
                fallback_out,
                fallback_wheel,
            )
            fallback_site_packages = _site_packages(fallback_out)
            assert "__init__.py" in hashed_names, name
            _assert_record_matches_installed_files(fallback_site_packages)

        duplicate_wheel = root / "duplicate-1.0-py3-none-any.whl"
        stale_digest = urlsafe_b64encode(hashlib.sha256(b"stale").digest()).decode().rstrip("=")
        _write_wheel(
            duplicate_wheel,
            "duplicate",
            {"fixture/__init__.py": b"VALUE = 1\n"},
            {"fixture/__init__.py": (f"sha256={stale_digest}", str(len(b"VALUE = 1\n")))},
            (("fixture/__init__.py", "", ""),),
        )
        duplicate_out = root / "duplicate"
        hashed_names.clear()
        unpack_module.install_wheel(
            sys.version_info.major,
            sys.version_info.minor,
            duplicate_out,
            duplicate_wheel,
        )
        duplicate_site_packages = _site_packages(duplicate_out)
        assert "__init__.py" in hashed_names
        _assert_record_matches_installed_files(duplicate_site_packages)

        duplicate_member_wheel = root / "duplicate_member-1.0-py3-none-any.whl"
        _write_wheel(
            duplicate_member_wheel,
            "duplicate_member",
            {"fixture/member.py": b"VALUE = 1\n"},
        )
        with zipfile.ZipFile(duplicate_member_wheel, "a") as archive:
            _write_member(archive, "fixture/member.py", b"VALUE = 2\n")
        duplicate_member_out = root / "duplicate_member"
        hashed_names.clear()
        unpack_module.install_wheel(
            sys.version_info.major,
            sys.version_info.minor,
            duplicate_member_out,
            duplicate_member_wheel,
        )
        duplicate_member_site_packages = _site_packages(duplicate_member_out)
        assert (duplicate_member_site_packages / "fixture" / "member.py").read_bytes() == (
            b"VALUE = 2\n"
        )
        assert "member.py" in hashed_names
        _assert_record_matches_installed_files(duplicate_member_site_packages)

        # A wheel that compiles cleanly installs successfully (exit 0) and
        # produces bytecode.
        good_wheel = root / "fixture-1.0-py3-none-any.whl"
        _build_wheel(good_wheel, legacy_syntax=False)
        good_out = root / "good"
        hashed_names.clear()
        original_argv = sys.argv
        sys.argv = [
            str(unpack),
            "--into",
            str(good_out),
            "--wheel",
            str(good_wheel),
            "--python-version-major",
            str(sys.version_info.major),
            "--python-version-minor",
            str(sys.version_info.minor),
            "--compile-pyc",
            "--python",
            sys.executable,
        ]
        try:
            unpack_module.main()
        finally:
            sys.argv = original_argv
        site_packages = (
            good_out
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        assert next((site_packages / "fixture" / "__pycache__").glob("*.pyc"))
        supplied_cache = (
            site_packages
            / "fixture"
            / "__pycache__"
            / f"mod.{sys.implementation.cache_tag}.pyc"
        )
        assert supplied_cache.read_bytes() != b"outdated bytecode\n"
        assert hashed_names == {"INSTALLER", "REQUESTED", supplied_cache.name}
        _assert_record_matches_installed_files(site_packages)
        recorded = {relative for relative, _, _ in _record_rows(site_packages)}
        assert supplied_cache.relative_to(site_packages).as_posix() in recorded
        assert Path(
            importlib.util.cache_from_source(str(site_packages / "fixture" / "__init__.py"))
        ).relative_to(site_packages).as_posix() not in recorded

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

        no_record_wheel = root / "no_record-1.0-py3-none-any.whl"
        with zipfile.ZipFile(no_record_wheel, "w") as archive:
            _write_member(archive, "fixture/__init__.py", b"VALUE = 1\n")
            _write_member(archive, "no_record-1.0.dist-info/METADATA", b"Name: no-record\n")
        no_record_out = root / "no-record"
        no_record = _run_unpack(
            unpack,
            no_record_wheel,
            no_record_out,
            Path(sys.executable),
        )
        assert no_record.returncode == 0, no_record.stdout + no_record.stderr
        assert (no_record_out / site_packages.relative_to(good_out) / "fixture" / "__init__.py").is_file()

        corrupt_wheel = root / "corrupt-1.0-py3-none-any.whl"
        corrupt_member = "corrupt-1.0.data/purelib/fixture/tests/corrupt.py"
        _write_wheel(
            corrupt_wheel,
            "corrupt",
            {
                "fixture/__init__.py": b"VALUE = 1\n",
                corrupt_member: b"raise AssertionError()\n",
            },
        )
        _corrupt_member(corrupt_wheel, corrupt_member)
        with zipfile.ZipFile(corrupt_wheel) as archive:
            assert archive.testzip() == corrupt_member
        corrupt_out = root / "corrupt"
        skipped = _run_unpack(
            unpack,
            corrupt_wheel,
            corrupt_out,
            Path(sys.executable),
            ("--exclude-glob=fixture/**/tests/**",),
        )
        assert skipped.returncode == 0, skipped.stdout + skipped.stderr
        assert not (
            corrupt_out
            / site_packages.relative_to(good_out)
            / "fixture"
            / "tests"
        ).exists()
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

        excluded_invalid_wheel = root / "excluded_invalid-1.0-py3-none-any.whl"
        _write_wheel(
            excluded_invalid_wheel,
            "excluded_invalid",
            {"../../../../escaped.py": b"escaped\n"},
        )
        excluded_invalid = _run_unpack(
            unpack,
            excluded_invalid_wheel,
            root / "excluded-invalid-out",
            Path(sys.executable),
            ("--exclude-glob=**",),
        )
        assert excluded_invalid.returncode != 0, (
            excluded_invalid.stdout + excluded_invalid.stderr
        )
        assert "Invalid wheel member path" in excluded_invalid.stderr

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
--- /dev/null
+++ b/{site_packages_relative}/fixture/added.py
@@ -0,0 +1 @@
+VALUE = 3
--- /dev/null
+++ b/{site_packages_relative}/fixture/__pycache__/added.{sys.implementation.cache_tag}.pyc
@@ -0,0 +1 @@
+outdated bytecode
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
        for cache in (
            content_site_packages
            / "fixture"
            / "__pycache__"
            / f"mod.{sys.implementation.cache_tag}.pyc",
            content_site_packages
            / "fixture"
            / "__pycache__"
            / f"added.{sys.implementation.cache_tag}.pyc",
        ):
            assert cache.read_bytes() != b"outdated bytecode\n"
        _assert_record_matches_installed_files(content_site_packages)
        assert {
            f"fixture/__pycache__/mod.{sys.implementation.cache_tag}.pyc",
            f"fixture/__pycache__/added.{sys.implementation.cache_tag}.pyc",
            "../../../share/supplied.pyc",
        } <= {
            relative for relative, _, _ in _record_rows(content_site_packages)
        }

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
        mutation_python = root / "python"
        mutation_python.symlink_to(sys.executable)
        mutation_tool.write_text(
            f"""#!{mutation_python}
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
        excluded_native = root / "excluded_native.patch"
        excluded_native.write_text(
            f"write-native\n{site_packages_relative}/fixture/tests/native_extension.so\n"
        )
        accepted = _run_unpack(
            unpack,
            good_wheel,
            root / "excluded-native",
            Path(sys.executable),
            (
                "--patch",
                str(excluded_native),
                "--patch-tool",
                str(mutation_tool),
                "--preserve-path",
                "fixture",
                "--exclude-glob=fixture/**/tests/**",
            ),
        )
        assert accepted.returncode == 0, accepted.stdout + accepted.stderr
        excluded_init = root / "excluded_init.patch"
        excluded_init.write_text(
            f"unlink\n{site_packages_relative}/fixture/__init__.py\n"
        )
        accepted = _run_unpack(
            unpack,
            good_wheel,
            root / "excluded-init",
            Path(sys.executable),
            (
                "--patch",
                str(excluded_init),
                "--patch-tool",
                str(mutation_tool),
                "--preserve-path",
                "fixture",
                "--exclude-glob=fixture/__init__.py",
            ),
        )
        assert accepted.returncode == 0, accepted.stdout + accepted.stderr

        functions = runpy.run_path(str(unpack.with_name("exclude_glob.py")))
        parse = functions["parse"]
        excluded = functions["excluded"]
        for path, glob, expected in [
            ("demo/tests/test_root.py", "demo/**/tests/**", True),
            ("demo/nested/tests/test_nested.py", "demo/**/tests/**", True),
            ("demo/nested/not_tests/test_nested.py", "demo/**/tests/**", False),
            ("google/api/annotations.proto", "google/**/*.proto", True),
            ("google/api/annotations_pb2.py", "google/**/*.proto", False),
            ("demo/data/sample,1.csv", "demo/data/sample,*.csv", True),
            ("demo/data/acb.txt", "demo/data/a*b*c.txt", False),
            ("demo/sdk-core/bin/tool", "demo/sdk-core", True),
            ("../../../bin/demo", "**", False),
        ]:
            assert excluded(tuple(path.split("/")), [parse(glob)]) == expected, (path, glob)

        filter_wheel = root / "demo-1.0-py3-none-any.whl"
        compiled_source = root / "compiled_source.py"
        compiled_source.write_text("VALUE = 1\n")
        compiled = root / "compiled.pyc"
        py_compile.compile(str(compiled_source), cfile=str(compiled), doraise=True)
        compiled_bytes = compiled.read_bytes()
        dotted_source = root / "test_api.v1.py"
        dotted_source.write_text("VALUE = 1\n")
        dotted = root / "test_api.v1.pyc"
        py_compile.compile(str(dotted_source), cfile=str(dotted), doraise=True)
        dotted_bytes = dotted.read_bytes()
        py_compile.compile(str(dotted_source), cfile=str(dotted), doraise=True, optimize=1)
        optimized_dotted_bytes = dotted.read_bytes()
        _write_wheel(
            filter_wheel,
            "demo",
            {
                "demo/__init__.py": b"VALUE = 1\n",
                "demo/keep.py": b"VALUE = 2\n",
                "demo/tests/test_root.py": b"raise AssertionError()\n",
                "demo/nested/tests/test_nested.py": b"raise AssertionError()\n",
                "demo/file_tests/test_one.py": b"raise AssertionError()\n",
                "demo/file_tests/test_legacy.py": b"raise AssertionError()\n",
                "demo/file_tests/__pycache__/test_one.cpython-311.pyc": b"shipped bytecode\n",
                "demo/file_tests/__pycache__/test_one.cpython-311.opt-1.pyc": b"optimized bytecode\n",
                "demo/file_tests/__pycache__/test_orphan.cpython-311.pyc": b"orphan bytecode\n",
                "demo/file_tests/test_legacy.pyc": b"legacy bytecode\n",
                "demo/__pycache__/keep.cpython-999.pyc": b"retained bytecode\n",
                "demo/keep.pyc": b"retained legacy bytecode\n",
                "demo/sdk-core/bin/tool": b"unused native payload\n",
                "pkg/__init__.py": b"VALUE = 1\n",
                "pkg/test_api.v1.py": b"raise AssertionError()\n",
                "pkg/__pycache__/test_api.v1.cpython-311.pyc": dotted_bytes,
                "pkg/__pycache__/test_api.v1.cpython-311.opt-1.pyc": optimized_dotted_bytes,
                "pkg/__pycache__/test_api.v1.cpython-311.opt-é.pyc": optimized_dotted_bytes,
                "pkg/.pyc": dotted_bytes,
                "google/api/annotations.proto": b"syntax = 'proto3';\n",
                "google/api/annotations_pb2.py": b"VALUE = 1\n",
                "generated_backend/__init__.py": b"VALUE = 1\n",
                "native_backend/backend.so.1": b"native\n",
                "compiled_only.pyc": compiled_bytes,
                "compiled_package/__init__.pyc": compiled_bytes,
                "demo-1.0.dist-info/helper.py": b"metadata helper\n",
                "demo-1.0.data/data/share/demo/retained.txt": b"installed data\n",
            },
        )
        filter_patch = root / "filter.patch"
        filter_patch.write_text(
            f"""\
--- a/{site_packages_relative}/demo/keep.py
+++ b/{site_packages_relative}/demo/keep.py
@@ -1 +1 @@
-VALUE = 2
+VALUE = 3
--- /dev/null
+++ b/{site_packages_relative}/demo/tests/from_patch.py
@@ -0,0 +1 @@
+raise AssertionError()
--- /dev/null
+++ b/share/demo/from_patch.txt
@@ -0,0 +1 @@
+patched data
"""
        )
        filtered_out = root / "filtered"
        filtered = _run_unpack(
            unpack,
            filter_wheel,
            filtered_out,
            Path(sys.executable),
            (
                "--patch",
                str(filter_patch),
                "--patch-strip",
                "1",
                "--preserve-path",
                "demo",
                "--preserve-path",
                "demo-1.0.dist-info",
                "--exclude-glob=demo/**/tests/**",
                "--exclude-glob=demo/file_tests/test_*.py",
                "--exclude-glob=demo/sdk-core",
                "--exclude-glob=pkg/test_*.py",
                "--exclude-glob=pkg/.py",
                "--exclude-glob=google/**/*.proto",
                "--exclude-glob=demo-1.0.dist-info/helper.py",
            ),
        )
        assert filtered.returncode == 0, filtered.stdout + filtered.stderr
        filtered_site_packages = filtered_out / site_packages_relative
        assert (filtered_site_packages / "demo" / "keep.py").read_text() == "VALUE = 3\n"
        assert not (filtered_site_packages / "demo" / "tests").exists()
        assert not (filtered_site_packages / "demo" / "nested" / "tests").exists()
        assert not list((filtered_site_packages / "demo" / "file_tests").glob("test_*"))
        assert not (filtered_site_packages / "demo" / "file_tests" / "__pycache__").exists()
        assert not (filtered_site_packages / "demo" / "sdk-core").exists()
        assert not (filtered_site_packages / "pkg" / "test_api.v1.py").exists()
        assert not (filtered_site_packages / "pkg" / "__pycache__" / "test_api.v1.cpython-311.pyc").exists()
        assert not (filtered_site_packages / "pkg" / "__pycache__" / "test_api.v1.cpython-311.opt-1.pyc").exists()
        assert not (filtered_site_packages / "pkg" / "__pycache__" / "test_api.v1.cpython-311.opt-é.pyc").exists()
        assert not (filtered_site_packages / "pkg" / ".pyc").exists()
        assert not (filtered_site_packages / "google" / "api" / "annotations.proto").exists()
        assert (filtered_site_packages / "google" / "api" / "annotations_pb2.py").is_file()
        assert next((filtered_site_packages / "demo" / "__pycache__").glob("keep.*.pyc"))
        assert (filtered_site_packages / "demo" / "__pycache__" / "keep.cpython-999.pyc").is_file()
        assert (filtered_site_packages / "demo" / "keep.pyc").is_file()
        assert not list(filtered_site_packages.rglob("test_*.pyc"))
        subprocess.run(
            [sys.executable, "-c", "import compiled_only, compiled_package"],
            check=True,
            env={"PYTHONPATH": str(filtered_site_packages)},
        )

        distribution, = importlib.metadata.distributions(path=[str(filtered_site_packages)])
        recorded = {str(path): path for path in distribution.files}
        assert "demo/keep.py" in recorded
        assert "../../../share/demo/retained.txt" in recorded
        assert "../../../share/demo/from_patch.txt" in recorded
        assert "demo/tests/test_root.py" not in recorded
        assert "demo/tests/from_patch.py" not in recorded
        assert "demo/nested/tests/test_nested.py" not in recorded
        assert not any(path.startswith("demo/file_tests/") for path in recorded)
        assert "demo/sdk-core/bin/tool" not in recorded
        assert "pkg/test_api.v1.py" not in recorded
        assert "pkg/__pycache__/test_api.v1.cpython-311.pyc" not in recorded
        assert "pkg/__pycache__/test_api.v1.cpython-311.opt-1.pyc" not in recorded
        assert "pkg/__pycache__/test_api.v1.cpython-311.opt-é.pyc" not in recorded
        assert "pkg/.pyc" not in recorded
        assert "google/api/annotations.proto" not in recorded
        assert "demo-1.0.dist-info/helper.py" not in recorded
        assert "demo/__pycache__/keep.cpython-999.pyc" in recorded
        assert "demo/keep.pyc" in recorded
        assert not any(
            path.endswith(".pyc")
            and path not in (
                "demo/__pycache__/keep.cpython-999.pyc",
                "demo/keep.pyc",
                "compiled_only.pyc",
                "compiled_package/__init__.pyc",
            )
            for path in recorded
        )
        for name, path in recorded.items():
            installed = filtered_site_packages / name
            assert installed.is_file(), name
            if name.endswith(".dist-info/RECORD"):
                assert path.hash is None and path.size is None
                continue
            assert path.size == installed.stat().st_size
            assert path.hash.mode == "sha256"
            digest = urlsafe_b64encode(hashlib.sha256(installed.read_bytes()).digest())
            assert path.hash.value == digest.decode().rstrip("=")

        for invalid in ["", "/demo", "demo/", "demo//tests", "../demo", "demo\\tests", "demo/**x", "demo/?.py"]:
            rejected = _run_unpack(
                unpack,
                filter_wheel,
                root / "invalid",
                Path(sys.executable),
                ("--exclude-glob", invalid),
            )
            assert rejected.returncode != 0, invalid
            assert "invalid wheel exclude glob" in rejected.stderr
        for glob, removed in [
            ("demo/**", "demo"),
            ("generated_backend/**", "generated_backend"),
            ("native_backend/**", "native_backend"),
            ("google/**", "google"),
            ("compiled_only.pyc", "compiled_only.pyc"),
            ("compiled_package/**", "compiled_package"),
        ]:
            rejected = _run_unpack(
                unpack,
                filter_wheel,
                root / removed,
                Path(sys.executable),
                ("--exclude-glob", glob),
            )
            assert rejected.returncode != 0, glob
            assert f"wheel exclusions removed top-level import roots: {removed}" in rejected.stderr

        for glob in ["demo-1.0.dist-info/RECORD", "demo-1.0.dist-info/**"]:
            rejected = _run_unpack(
                unpack,
                filter_wheel,
                root / "removed-record",
                Path(sys.executable),
                ("--exclude-glob", glob),
            )
            assert rejected.returncode != 0, glob
            assert "expected exactly one installed RECORD, found 0" in rejected.stderr

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
            ("--exclude-glob=entry_point-1.0.dist-info/entry_points.txt",),
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
        assert not (
            site_packages / "entry_point-1.0.dist-info" / "entry_points.txt"
        ).exists()
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
