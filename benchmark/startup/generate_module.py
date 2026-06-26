#!/usr/bin/env python3
"""Generate MODULE.bazel for the benchmark workspace from a template.

Replaces fragile sed-based mutation with explicit, validated generation.
"""

import argparse
import sys
from pathlib import Path

TEMPLATE = Path(__file__).with_name("MODULE.bazel.template")
OUTPUT = Path(__file__).with_name("MODULE.bazel")


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

    if args.dry_run:
        print(result)
    else:
        OUTPUT.write_text(result)
        print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
