import csv
import hashlib
import importlib.metadata
import runpy
import subprocess
import sys
import tempfile
from base64 import urlsafe_b64encode
from pathlib import Path


def _run_filter(tool, source, output, *extra_args):
    return subprocess.run(
        [
            sys.executable,
            str(tool),
            "--from",
            str(source),
            "--into",
            str(output),
            "--python-version-major",
            str(sys.version_info.major),
            "--python-version-minor",
            str(sys.version_info.minor),
            *extra_args,
        ],
        capture_output=True,
        text=True,
    )


def main():
    tool = Path(sys.argv[1])
    functions = runpy.run_path(str(tool.with_name("exclude_glob.py")))
    pattern = functions["parse"]
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
        assert excluded(tuple(path.split("/")), [pattern(glob)]) == expected, (path, glob)

    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        source = root / "source"
        relative = (
            Path("lib")
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        site_packages = source / relative
        members = {
            "demo/__init__.py": "VALUE = 1\n",
            "demo/keep.py": "VALUE = 2\n",
            "demo/tests/test_root.py": "raise AssertionError()\n",
            "demo/nested/tests/test_nested.py": "raise AssertionError()\n",
            "demo/file_tests/test_one.py": "raise AssertionError()\n",
            "demo/file_tests/test_legacy.py": "raise AssertionError()\n",
            "demo/file_tests/__pycache__/test_one.cpython-311.pyc": "shipped bytecode\n",
            "demo/file_tests/__pycache__/test_one.cpython-311.opt-1.pyc": "optimized bytecode\n",
            "demo/file_tests/__pycache__/test_orphan.cpython-311.pyc": "orphan bytecode\n",
            "demo/file_tests/test_legacy.pyc": "legacy bytecode\n",
            "demo/__pycache__/keep.cpython-999.pyc": "retained bytecode\n",
            "demo/keep.pyc": "retained legacy bytecode\n",
            "demo/sdk-core/bin/tool": "unused native payload\n",
            "google/api/annotations.proto": "syntax = 'proto3';\n",
            "google/api/annotations_pb2.py": "VALUE = 1\n",
            "generated_backend/__init__.py": "VALUE = 1\n",
            "native_backend/backend.so.1": "native\n",
            "demo-1.0.dist-info/METADATA": "Name: demo\nVersion: 1.0\n",
            "demo-1.0.dist-info/helper.py": "metadata helper\n",
        }
        for name, content in members.items():
            path = site_packages / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        patched_data = source / "share" / "demo" / "retained.txt"
        patched_data.parent.mkdir(parents=True)
        patched_data.write_text("patched data\n")
        executable = source / "bin" / "demo"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        record = site_packages / "demo-1.0.dist-info" / "RECORD"
        with record.open("w", newline="", encoding="utf-8") as stream:
            csv.writer(stream).writerows(
                [[name, "sha256=stale", "1"] for name in members]
                + [["../../../bin/demo", "sha256=stale", "1"], ["demo-1.0.dist-info/RECORD", "", ""]]
            )

        backing = root / "backing"
        for path in list(source.rglob("*")):
            if not path.is_file():
                continue
            destination = backing / path.relative_to(source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            path.replace(destination)
            destination.chmod(0o555 if destination.name == "demo" else 0o444)
            path.symlink_to(destination)
        backing_record = backing / relative / "demo-1.0.dist-info" / "RECORD"
        original_record = backing_record.read_bytes()

        output = root / "filtered"
        output.mkdir()
        filtered = _run_filter(
            tool,
            source,
            output,
            "--exclude-glob=demo/**/tests/**",
            "--exclude-glob=demo/file_tests/test_*.py",
            "--exclude-glob=demo/sdk-core",
            "--exclude-glob=google/**/*.proto",
            "--exclude-glob=demo-1.0.dist-info/helper.py",
            "--compile-pyc",
            "--python",
            sys.executable,
        )
        assert filtered.returncode == 0, filtered.stdout + filtered.stderr
        filtered_site_packages = output / relative
        assert (filtered_site_packages / "demo" / "keep.py").is_file()
        assert not (filtered_site_packages / "demo" / "tests").exists()
        assert not (filtered_site_packages / "demo" / "nested" / "tests").exists()
        assert not list((filtered_site_packages / "demo" / "file_tests").glob("test_*"))
        assert not (filtered_site_packages / "demo" / "file_tests" / "__pycache__").exists()
        assert not (filtered_site_packages / "demo" / "sdk-core").exists()
        assert not (filtered_site_packages / "google" / "api" / "annotations.proto").exists()
        assert (filtered_site_packages / "google" / "api" / "annotations_pb2.py").is_file()
        assert next((filtered_site_packages / "demo" / "__pycache__").glob("keep.*.pyc"))
        assert (filtered_site_packages / "demo" / "__pycache__" / "keep.cpython-999.pyc").is_file()
        assert (filtered_site_packages / "demo" / "keep.pyc").is_file()
        assert not list(filtered_site_packages.rglob("test_*.pyc"))
        assert (output / "bin" / "demo").stat().st_mode & 0o111
        assert not any(path.is_symlink() for path in output.rglob("*"))
        assert backing_record.read_bytes() == original_record

        distribution, = importlib.metadata.distributions(path=[str(filtered_site_packages)])
        recorded = {str(path): path for path in distribution.files}
        assert "demo/keep.py" in recorded
        assert "../../../bin/demo" in recorded
        assert "../../../share/demo/retained.txt" in recorded
        assert "demo/tests/test_root.py" not in recorded
        assert "demo/nested/tests/test_nested.py" not in recorded
        assert not any(path.startswith("demo/file_tests/") for path in recorded)
        assert "demo/sdk-core/bin/tool" not in recorded
        assert "google/api/annotations.proto" not in recorded
        assert "demo-1.0.dist-info/helper.py" not in recorded
        assert "demo/__pycache__/keep.cpython-999.pyc" in recorded
        assert "demo/keep.pyc" in recorded
        assert not any(path.endswith(".pyc") and "keep.cpython-999.pyc" not in path and path != "demo/keep.pyc" for path in recorded)
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
            rejected = _run_filter(tool, source, root / "invalid", "--exclude-glob", invalid)
            assert rejected.returncode != 0, invalid
            assert "invalid wheel exclude glob" in rejected.stderr
        for glob, removed in [
            ("demo/**", "demo"),
            ("generated_backend/**", "generated_backend"),
            ("native_backend/**", "native_backend"),
            ("google/**", "google"),
        ]:
            rejected = _run_filter(tool, source, root / removed, "--exclude-glob", glob)
            assert rejected.returncode != 0, glob
            assert f"wheel exclusions removed top-level import roots: {removed}" in rejected.stderr


if __name__ == "__main__":
    main()
