#!/usr/bin/env python3
"""Generate a synthetic Python workspace for the analysis benchmark.

Creates N local packages, M binaries, and M tests across multiple BUILD files to
exercise Bazel's analysis phase with rules_py.
"""

from __future__ import annotations

import argparse
import random
import shutil
import sys
from pathlib import Path

EXTERNAL_DEPS = [
    "django",
    "requests",
    "pydantic",
    "click",
    "rich",
    "pytest",
    "jinja2",
    "pyyaml",
    "flask",
    "sqlalchemy",
    "celery",
    "boto3",
    "beautifulsoup4",
    "graphene",
    "fastapi",
    "httpx",
    "aiohttp",
    "pydantic_settings",
    "marshmallow",
    "jsonschema",
    "ipython",
    "sphinx",
    "mkdocs",
    "factory_boy",
    "faker",
    "djangorestframework",
]

LIBRARY_BUILD_TEMPLATE = '''load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_library")

py_library(
    name = "{name}",
    srcs = [
        "__init__.py",
        "lib.py",
    ],
    imports = [".."],
    visibility = ["//visibility:public"],
    deps = {deps},
)

py_binary(
    name = "{name}_bin",
    srcs = ["main.py"],
    main = "main.py",
    visibility = ["//visibility:public"],
    deps = [":{name}"],
)
'''

TEST_BUILD_TEMPLATE = '''load("@aspect_rules_py//py:defs.bzl", "py_test")

py_test(
    name = "{name}_test",
    srcs = ["test.py"],
    main = "test.py",
    deps = ["//workspace/src/{name}:{name}"],
)
'''

INIT_TEMPLATE = '''"""Generated package {name}."""

from {name}.lib import compute

__all__ = ["compute"]
'''

LIB_TEMPLATE = '''"""Generated library for package {name}."""

{imports}

VALUE = {value}


def compute(x: int) -> int:
    """Return a deterministic transformation of x."""
    return x * {multiplier} + {offset}
'''

MAIN_TEMPLATE = '''"""Generated binary for package {name}."""

import sys

from {name}.lib import compute


def main() -> int:
    print("{name}", compute(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
'''

TEST_TEMPLATE = '''"""Generated test for package {name}."""

from {name}.lib import compute


def test_compute():
    assert compute(0) == {offset}
    assert compute(1) == {multiplier} + {offset}
'''


def generate_package(pkg_dir: Path, name: str, deps: list[str], seed: int) -> None:
    """Generate source and BUILD files for one local package."""
    pkg_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(seed)
    multiplier = rng.randint(2, 100)
    offset = rng.randint(1, 1000)

    local_deps = [d for d in deps if d.startswith("//")]
    external_deps = [d for d in deps if not d.startswith("//")]

    imports = []
    for dep in local_deps:
        # dep looks like "//src/pkg_0:pkg_0" -> import pkg_0.lib
        dep_name = dep.split(":")[-1]
        imports.append(f"from {dep_name}.lib import compute as _{dep_name}_compute")

    # External deps are just imported to create real load-time edges.
    for dep in external_deps:
        imports.append(f"import {dep.split('//')[-1]}")

    (pkg_dir / "__init__.py").write_text(INIT_TEMPLATE.format(name=name))
    (pkg_dir / "lib.py").write_text(
        LIB_TEMPLATE.format(
            name=name,
            imports="\n".join(imports),
            value=offset,
            multiplier=multiplier,
            offset=offset,
        )
    )
    (pkg_dir / "main.py").write_text(MAIN_TEMPLATE.format(name=name))
    (pkg_dir / "BUILD.bazel").write_text(
        LIBRARY_BUILD_TEMPLATE.format(
            name=name,
            deps=str(external_deps + local_deps),
        )
    )

    test_dir = pkg_dir.parent.with_name("tests") / name
    test_dir.mkdir(parents=True, exist_ok=True)
    (test_dir / "test.py").write_text(
        TEST_TEMPLATE.format(name=name, multiplier=multiplier, offset=offset)
    )
    (test_dir / "BUILD.bazel").write_text(
        TEST_BUILD_TEMPLATE.format(
            name=name,
        )
    )


def generate_root_build(root: Path, package_count: int) -> None:
    """Generate a root BUILD that groups all binaries."""
    lines = ['load("@bazel_skylib//rules:build_test.bzl", "build_test")\n\n']
    lines.append('build_test(\n')
    lines.append('    name = "all_bins",\n')
    targets = [f"//workspace/src/pkg_{i}:pkg_{i}_bin" for i in range(package_count)]
    lines.append(f"    targets = {targets},\n")
    lines.append(')\n')
    (root / "BUILD.bazel").write_text("".join(lines))


def clean_generated(root: Path) -> None:
    """Remove previously generated package directories."""
    for base in (root / "src", root / "tests"):
        if not base.exists():
            continue
        for old in list(base.iterdir()):
            if old.name.startswith("pkg_"):
                shutil.rmtree(old)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate synthetic analysis benchmark workspace")
    parser.add_argument(
        "--root",
        default=".",
        help="Workspace root directory (default: current directory)",
    )
    parser.add_argument(
        "--packages",
        type=int,
        default=50,
        help="Number of local packages to generate (default: 50)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducibility (default: 42)",
    )
    args = parser.parse_args()

    root = Path(args.root)
    src = root / "src"
    rng = random.Random(args.seed)

    clean_generated(root)

    for i in range(args.packages):
        name = f"pkg_{i}"
        pkg_dir = src / name

        # Each package depends on 0-3 earlier local packages and 1-2 external deps.
        local_deps = []
        if i > 0:
            local_count = rng.randint(1, min(3, i))
            local_deps = [
                f"//workspace/src/pkg_{j}:pkg_{j}"
                for j in sorted(rng.sample(range(i), local_count))
            ]

        external_count = rng.randint(1, 2)
        external_deps = [f"@pypi//{d}" for d in rng.sample(EXTERNAL_DEPS, external_count)]

        generate_package(pkg_dir, name, external_deps + local_deps, seed=args.seed + i)

    generate_root_build(root, args.packages)
    print(f"Generated {args.packages} packages under {src}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
