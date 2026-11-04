#!/usr/bin/env python3
"""Generate MODULE.bazel for the benchmark workspace from a template.

Replaces fragile sed-based mutation with explicit, validated generation.
"""

import argparse
import re
import sys
from pathlib import Path

TEMPLATE = Path(__file__).with_name("MODULE.bazel.template")
OUTPUT = Path(__file__).with_name("MODULE.bazel")
# Last BCR release published as aspect_rules_py; later ones are rules_py.
LAST_ASPECT_RULES_PY_RELEASE = "2.0.0-alpha.10"


def _version_key(version: str) -> tuple:
    base, _, pre = version.partition("-")
    key = tuple(int(part) for part in base.split("."))
    if not pre:
        return key + ((1,),)
    name, _, number = pre.partition(".")
    return key + ((0, name, int(number or 0)),)


def module_name(mode: str, version: str, path: str) -> str:
    """Module name of the rules_py under test, which was published as aspect_rules_py before the rename.

    A relative `path` is resolved against this script's directory.
    """
    if mode == "bcr":
        if _version_key(version) <= _version_key(LAST_ASPECT_RULES_PY_RELEASE):
            return "aspect_rules_py"
        return "rules_py"
    module_file = Path(__file__).parent / path / "MODULE.bazel"
    match = re.search(r'\bmodule\([^)]*?\bname\s*=\s*"([^"]+)"', module_file.read_text(), re.DOTALL)
    if not match:
        print(f"ERROR: no module name found in {module_file}", file=sys.stderr)
        sys.exit(1)
    return match.group(1)


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
    parser = argparse.ArgumentParser(description="Generate MODULE.bazel for benchmark")
    parser.add_argument(
        "mode",
        choices=["bcr", "local"],
        help="'bcr' pins to a BCR release; 'local' uses local_path_override",
    )
    parser.add_argument(
        "--version",
        default="1.11.7",
        help="BCR version to pin when mode=bcr (default: 1.11.7)",
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

    name = module_name(args.mode, args.version, args.path)
    if args.mode == "bcr":
        declaration = f'bazel_dep(name = "{name}", version = "{args.version}", repo_name = "rules_py")'
    else:
        declaration = (
            f'bazel_dep(name = "{name}", repo_name = "rules_py")\n'
            f'local_path_override(\n'
            f'    module_name = "{name}",\n'
            f'    path = "{args.path}",\n'
            f')'
        )

    result = generate(declaration)

    if args.dry_run:
        print(result)
    else:
        OUTPUT.write_text(result)
        print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
