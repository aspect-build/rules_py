#!/usr/bin/env python3
"""Generate MODULE.bazel for the analysis benchmark workspace from a template."""

import argparse
import sys
from pathlib import Path

TEMPLATE = Path(__file__).with_name("MODULE.bazel.template")
OUTPUT = Path(__file__).with_name("MODULE.bazel")
PATCH = Path(__file__).parent / "workspace" / "patches" / "wheel_bench_note.patch"

# Releases through 2.0.0-alpha.6 apply post-install patches from the install
# prefix; later rules_py applies them from site-packages.
LAST_PREFIX_ANCHORED_RELEASE = "2.0.0-alpha.6"
SITE_PACKAGES_ANCHOR_MARKER = "Paths are site-packages-relative."
PATCH_TEMPLATE = """--- /dev/null
+++ b/{prefix}click/_bench_note.py
@@ -0,0 +1 @@
+BENCH_TICK = 0
"""


def _version_key(version: str) -> tuple:
    base, _, pre = version.partition("-")
    key = tuple(int(part) for part in base.split("."))
    if not pre:
        return key + ((1,),)
    name, _, number = pre.partition(".")
    return key + ((0, name, int(number or 0)),)


def prefix_anchored(mode: str, version: str, path: str) -> bool:
    if mode == "bcr":
        return _version_key(version) <= _version_key(LAST_PREFIX_ANCHORED_RELEASE)
    defs = Path(path, "uv/private/extension/defs.bzl").read_text()
    return SITE_PACKAGES_ANCHOR_MARKER not in defs


def patch_path_prefix(mode: str, version: str, path: str) -> str:
    return "lib/python3.11/site-packages/" if prefix_anchored(mode, version, path) else ""


def generate(declaration: str) -> str:
    """Substitute {{RULES_PY_DECLARATION}} in the template."""
    if not TEMPLATE.exists():
        print(f"ERROR: template not found: {TEMPLATE}", file=sys.stderr)
        sys.exit(1)

    content = TEMPLATE.read_text()
    if "{{RULES_PY_DECLARATION}}" not in content:
        print("ERROR: template missing {{RULES_PY_DECLARATION}} placeholder", file=sys.stderr)
        sys.exit(1)

    return content.replace("{{RULES_PY_DECLARATION}}", declaration)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate MODULE.bazel for analysis benchmark")
    parser.add_argument(
        "mode",
        choices=["bcr", "local"],
        help="'bcr' pins to a BCR release; 'local' uses local_path_override",
    )
    parser.add_argument(
        "--version",
        default="2.0.0-alpha.6",
        help="BCR version to pin when mode=bcr (default: 2.0.0-alpha.6)",
    )
    parser.add_argument(
        "--path",
        default="../..",
        help="Local path for local_path_override when mode=local (default: ../..)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print to stdout instead of writing MODULE.bazel",
    )
    args = parser.parse_args()

    if args.mode == "bcr":
        declaration = f'bazel_dep(name = "aspect_rules_py", version = "{args.version}")'
    else:
        declaration = (
            f'bazel_dep(name = "aspect_rules_py")\n'
            f'local_path_override(\n'
            f'    module_name = "aspect_rules_py",\n'
            f'    path = "{args.path}",\n'
            f')'
        )

    result = generate(declaration)

    patch = PATCH_TEMPLATE.format(prefix=patch_path_prefix(args.mode, args.version, args.path))

    if args.dry_run:
        print(result)
        print(patch)
    else:
        OUTPUT.write_text(result)
        PATCH.write_text(patch)
        print(f"Wrote {OUTPUT} and {PATCH}")


if __name__ == "__main__":
    main()
