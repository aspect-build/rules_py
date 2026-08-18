#!/usr/bin/env python3
"""Rewrite the click benchmark patch to simulate an incremental wheel change.

The patch is a build-phase input to click's whl_install action: changing its
content invalidates the installed wheel TreeArtifact (and everything downstream)
without any repository refetch.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

TEMPLATE = """--- /dev/null
+++ b/lib/python3.11/site-packages/click/_bench_note.py
@@ -0,0 +1 @@
+BENCH_TICK = {tick}
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Write the wheel-change benchmark patch")
    parser.add_argument("patch_file", help="Path to the patch file to (re)write")
    parser.add_argument(
        "--tick",
        default="auto",
        help="Value for BENCH_TICK; 'auto' uses a nanosecond timestamp (default: auto)",
    )
    args = parser.parse_args()

    tick = time.time_ns() if args.tick == "auto" else args.tick
    Path(args.patch_file).write_text(TEMPLATE.format(tick=tick))


if __name__ == "__main__":
    main()
