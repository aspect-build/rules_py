#!/usr/bin/env python3
"""E2E test: verify that uv.gazelle_manifest() generates a valid gazelle_python.yaml."""

import sys


def main(yaml_path):
    with open(yaml_path) as f:
        content = f.read()

    assert content.strip(), "gazelle_python.yaml is empty"
    assert "modules_mapping:" in content, (
        f"expected 'modules_mapping:' section in:\n{content}"
    )
    assert "cowsay: cowsay" in content, (
        f"expected 'cowsay: cowsay' mapping in:\n{content}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(
            "Usage: test_gazelle_manifest.py <path-to-gazelle_python.yaml>",
            file=sys.stderr,
        )
        sys.exit(1)
    main(sys.argv[1])
