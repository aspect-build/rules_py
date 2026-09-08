#!/usr/bin/env python3
"""Bump BENCH_TICK in the click benchmark patch to simulate an incremental wheel change.

The patch is a build-phase input to click's whl_install action: changing its
content invalidates the installed wheel TreeArtifact (and everything downstream)
without any repository refetch. generate_module.py writes the patch itself; its
header depends on the rules_py variant under test.
"""

from __future__ import annotations

import argparse
import re
import time
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Bump the wheel-change benchmark patch")
    parser.add_argument("patch_file", help="Path to the patch file to rewrite")
    args = parser.parse_args()

    patch = Path(args.patch_file)
    content, count = re.subn(r"BENCH_TICK = \d+", f"BENCH_TICK = {time.time_ns()}", patch.read_text())
    if count != 1:
        raise SystemExit(f"{patch}: expected exactly one BENCH_TICK line, found {count}")
    patch.write_text(content)


if __name__ == "__main__":
    main()
