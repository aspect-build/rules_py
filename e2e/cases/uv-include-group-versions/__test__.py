#!/usr/bin/env python3
"""Test that PEP 735 include-group version preferences are preserved.

This project declares two pairs of conflicting dependency groups:
- igv-build-base / igv-build use packaging==24.0
- igv-test-base / igv-test use packaging==21.3

Each outer group includes its base group via {include-group = ...}. uv.lock
records a different packaging version for each group. This test verifies that
rules_py installs the per-group version selected by uv.lock.
"""

import sys
from importlib.metadata import version

GROUPS = {
    "igv-build": "24.0",
    "igv-test": "21.3",
}


def main():
    group = sys.argv[1] if len(sys.argv) > 1 else "igv-build"
    expected = GROUPS[group]
    actual = version("packaging")
    print(f"{group}/packaging: {actual} (expected {expected})")
    assert actual == expected, (
        f"Expected packaging=={expected} for {group} group, got {actual}"
    )


if __name__ == "__main__":
    main()
