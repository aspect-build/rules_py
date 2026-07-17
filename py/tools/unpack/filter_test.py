import csv
import importlib.metadata
import runpy
import subprocess
import sys
import tempfile
from pathlib import Path


def _run_filter(
    tool: Path,
    source: Path,
    output: Path,
    *extra_args: str,
) -> subprocess.CompletedProcess:
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


def main() -> None:
    tool = Path(sys.argv[1])
    functions = runpy.run_path(str(tool.with_name("exclude_glob.py")))
    pattern = functions["parse"]
    excluded = functions["excluded"]

    cases = [
        ("demo/tests/test_root.py", "demo/**/tests/**", True),
        ("demo/nested/tests/test_nested.py", "demo/**/tests/**", True),
        ("demo/nested/not_tests/test_nested.py", "demo/**/tests/**", False),
        ("demo/data/value.proto", "**/*.proto", True),
        ("demo/value.proto", "**/*.proto", True),
        ("demo/data/value.py", "**/*.proto", False),
        ("demo/data/a.json", "demo/data/*.json", True),
        ("demo/data/nested/a.json", "demo/data/*.json", False),
        ("demo/data/sample,1.csv", "demo/data/sample,*.csv", True),
        ("demo/data/abc.txt", "demo/data/a*b*c.txt", True),
        ("demo/data/acb.txt", "demo/data/a*b*c.txt", False),
        ("tests/test_demo.py", "tests/**", True),
        ("demo/native.so", "demo/*.so", True),
        ("tests/test_demo.py", "tests", True),
        ("other/tests/test_demo.py", "tests", False),
        ("google/api/nested/value.proto", "google/api", True),
        ("google/rpc/status_pb2.py", "google/api", False),
        ("pkg/nested/native.so", "pkg/*", True),
        ("pkg/module.py", "pkg/*", True),
        ("other/pkg/module.py", "pkg/*", False),
        ("../../../bin/demo", "**", False),
    ]
    for path, glob, expected in cases:
        assert excluded(tuple(path.split("/")), [pattern(glob)]) == expected, (path, glob)

    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        source = root / "source"
        site_packages_relative = (
            Path("lib")
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        site_packages = source / site_packages_relative
        members = {
            "demo/__init__.py": "VALUE = 1\n",
            "demo/keep.py": "VALUE = 2\n",
            "demo/tests/test_root.py": "raise AssertionError()\n",
            "demo/nested/tests/test_nested.py": "raise AssertionError()\n",
            "demo/data/value.proto": "syntax = 'proto3';\n",
            "demo/data/value,2.proto": "syntax = 'proto3';\n",
            "demo/data/keep.txt": "kept\n",
            "demo/data/keep,2.txt": "kept\n",
            "demo/native.so": "native\n",
            "tests/test_root.py": "raise AssertionError()\n",
            "google/api/nested/value.proto": "syntax = 'proto3';\n",
            "google/api/annotations_pb2.py": "VALUE = 1\n",
            "google/rpc/status_pb2.py": "VALUE = 1\n",
            "pkg/__init__.py": "VALUE = 1\n",
            "pkg/nested/native.so": "native\n",
            "-vendor/tests/test_vendor.py": "raise AssertionError()\n",
            "demo-1.0.dist-info/METADATA": "Name: demo\nVersion: 1.0\n",
        }
        for name, content in members.items():
            member = site_packages / name
            member.parent.mkdir(parents=True, exist_ok=True)
            member.write_text(content)
        executable = source / "bin" / "demo"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        external_tests = source / "bin" / "tests"
        external_tests.write_text("#!/bin/sh\nexit 0\n")
        record = site_packages / "demo-1.0.dist-info" / "RECORD"
        with record.open("w", newline="", encoding="utf-8") as stream:
            csv.writer(stream).writerows(
                [[name, "sha256=placeholder", "1"] for name in members]
                + [
                    ["../../../bin/demo", "sha256=placeholder", "1"],
                    ["../../../bin/tests", "sha256=placeholder", "1"],
                    ["demo-1.0.dist-info/RECORD", "", ""],
                ]
            )

        # Bazel presents TreeArtifact members as read-only input symlinks.
        backing = root / "backing"
        for member in list(source.rglob("*")):
            if not member.is_file():
                continue
            destination = backing / member.relative_to(source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            member.replace(destination)
            destination.chmod(0o555 if destination.name == "demo" else 0o444)
            member.symlink_to(destination)
        backing_record = backing / site_packages_relative / "demo-1.0.dist-info" / "RECORD"
        original_record = backing_record.read_bytes()

        output = root / "filtered"
        # Bazel pre-creates declared directory outputs before invoking actions.
        output.mkdir()
        filtered = _run_filter(
            tool,
            source,
            output,
            "--exclude-glob",
            "demo/**/tests/**",
            "--exclude-glob",
            "**/*.proto",
            "--exclude-glob",
            "tests",
            "--exclude-glob",
            "**/tests",
            "--exclude-glob",
            "google/api",
            "--exclude-glob=pkg/*",
            "--exclude-glob=-vendor/tests",
            "--compile-pyc",
            "--python",
            sys.executable,
        )
        assert filtered.returncode == 0, filtered.stdout + filtered.stderr
        filtered_site_packages = output / site_packages_relative
        assert (filtered_site_packages / "demo" / "keep.py").is_file()
        assert (filtered_site_packages / "demo" / "data" / "keep.txt").is_file()
        assert not (filtered_site_packages / "demo" / "tests").exists()
        assert not (filtered_site_packages / "demo" / "nested" / "tests").exists()
        assert not (filtered_site_packages / "demo" / "data" / "value.proto").exists()
        assert not (filtered_site_packages / "demo" / "data" / "value,2.proto").exists()
        assert not (filtered_site_packages / "tests").exists()
        assert not (filtered_site_packages / "google" / "api").exists()
        assert (filtered_site_packages / "google" / "rpc" / "status_pb2.py").is_file()
        assert not (filtered_site_packages / "pkg" / "nested").exists()
        assert not (filtered_site_packages / "pkg" / "__init__.py").exists()
        assert not (filtered_site_packages / "-vendor" / "tests").exists()
        assert next((filtered_site_packages / "demo" / "__pycache__").glob("keep.*.pyc"))
        assert not list(filtered_site_packages.rglob("test_*.pyc"))
        assert (output / "bin" / "demo").stat().st_mode & 0o111
        assert (output / "bin" / "tests").is_file()
        assert not any(member.is_symlink() for member in output.rglob("*"))
        assert backing_record.read_bytes() == original_record
        assert not backing_record.stat().st_mode & 0o222
        assert (filtered_site_packages / "demo-1.0.dist-info" / "RECORD").stat().st_mode & 0o200

        distribution, = importlib.metadata.distributions(path=[str(filtered_site_packages)])
        recorded = {str(path) for path in distribution.files}
        assert "demo/data/keep,2.txt" in recorded
        assert "../../../bin/demo" in recorded
        assert "../../../bin/tests" in recorded
        assert "demo-1.0.dist-info/RECORD" in recorded
        assert "demo/tests/test_root.py" not in recorded
        assert "demo/nested/tests/test_nested.py" not in recorded
        assert "demo/data/value.proto" not in recorded
        assert "demo/data/value,2.proto" not in recorded
        assert "tests/test_root.py" not in recorded
        assert "google/api/nested/value.proto" not in recorded
        assert "google/api/annotations_pb2.py" not in recorded
        assert "google/rpc/status_pb2.py" in recorded
        assert "pkg/__init__.py" not in recorded
        assert "pkg/nested/native.so" not in recorded
        assert "-vendor/tests/test_vendor.py" not in recorded

        for invalid in [
            "",
            "/demo",
            "demo/",
            "demo//tests",
            "../demo",
            "demo/../x",
            "demo\\tests",
            "demo/**x",
            "C:/demo",
            "demo/?.py",
            "demo/[ab].py",
        ]:
            rejected = _run_filter(tool, source, root / "invalid", "--exclude-glob", invalid)
            assert rejected.returncode != 0, invalid
            assert "invalid wheel exclude glob" in rejected.stderr

        for name, excluded, removed in [
            ("reclassified", "demo/__init__.py", "demo/__init__.py"),
            ("native", "demo/native.so", "demo/native.so"),
            ("removed", "demo/**", "demo"),
        ]:
            filtered = _run_filter(
                tool,
                source,
                root / name,
                "--exclude-glob",
                excluded,
            )
            assert filtered.returncode == 0, filtered.stdout + filtered.stderr
            assert not (root / name / site_packages_relative / removed).exists()


if __name__ == "__main__":
    main()
