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


def generate_root_build(
    root: Path,
    package_count: int,
    image_binaries: int,
    image_layer_groups: bool = False,
    image_common_dep: str | None = None,
) -> None:
    """Generate a root BUILD that groups all binaries."""
    rules = '"py_image_layer", "py_layer_tier"' if image_layer_groups else '"py_image_layer"'
    lines = [f'load("@aspect_rules_py//py:defs.bzl", {rules})\n']
    lines.append('load("@bazel_skylib//rules:build_test.bzl", "build_test")\n\n')
    lines.append('build_test(\n')
    lines.append('    name = "all_bins",\n')
    targets = [f"//workspace/src/pkg_{i}:pkg_{i}_bin" for i in range(package_count)]
    lines.append(f"    targets = {targets},\n")
    lines.append(')\n\n')

    # A grouped tier instantiates every layer family (first-party, solo pip,
    # interpreter), so the cross-layer exclusion and symlink-mapping pipeline
    # is part of the measured graph. The last package's library is the
    # 1p-mutation target, so its group's rebuild cost is measured too.
    if image_layer_groups:
        last = package_count - 1
        lines.append('py_layer_tier(\n')
        lines.append('    name = "image_tier",\n')
        lines.append('    groups = {\n')
        lines.append(f'        "//workspace/src/pkg_{last}:pkg_{last}": "first_party",\n')
        if image_common_dep:
            lines.append(f'        "@pip//{image_common_dep}": "{image_common_dep}",\n')
        lines.append('    },\n')
        lines.append('    interpreter_group = "interpreter",\n')
        lines.append(')\n\n')

    # Multi-binary image layers: the last N packages have the deepest dep
    # closures, stressing the py_image_layer aspects during analysis.
    image_bins = targets[-image_binaries:] if image_binaries else []
    lines.append('py_image_layer(\n')
    lines.append('    name = "image_layers",\n')
    lines.append(f"    binaries = {image_bins},\n")
    if image_layer_groups:
        lines.append('    layer_tier = ":image_tier",\n')
    lines.append('    # The synthetic dep closure squashes >200MB of wheels into one pip layer;\n')
    lines.append('    # this benchmark measures action fanout, not layer-size hygiene.\n')
    lines.append('    warn_remote_cache_threshold_mb = 1024,\n')
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
        "--image-binaries",
        type=int,
        default=10,
        help="Number of binaries in the py_image_layer target (default: 10)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducibility (default: 42)",
    )
    parser.add_argument(
        "--external-deps",
        help="Comma-separated external dep pool to sample from (default: the full built-in list)",
    )
    parser.add_argument(
        "--image-common-dep",
        help="External dep added to every image binary's package, guaranteeing it is in each image dep closure",
    )
    parser.add_argument(
        "--image-layer-groups",
        action="store_true",
        help="Give the image target a py_layer_tier with first-party, pip, and interpreter groups",
    )
    args = parser.parse_args()

    root = Path(args.root)
    src = root / "src"
    rng = random.Random(args.seed)

    dep_pool = args.external_deps.split(",") if args.external_deps else EXTERNAL_DEPS
    image_binaries = min(args.image_binaries, args.packages)

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

        external_count = rng.randint(1, min(2, len(dep_pool)))
        external_deps = [f"@pypi//{d}" for d in rng.sample(dep_pool, external_count)]

        if args.image_common_dep and i >= args.packages - image_binaries:
            common = f"@pypi//{args.image_common_dep}"
            if common not in external_deps:
                external_deps.append(common)

        generate_package(pkg_dir, name, external_deps + local_deps, seed=args.seed + i)

    generate_root_build(
        root,
        args.packages,
        image_binaries,
        image_layer_groups=args.image_layer_groups,
        image_common_dep=args.image_common_dep,
    )
    print(f"Generated {args.packages} packages under {src}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
