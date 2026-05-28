#!/usr/bin/env python3
"""Output sys.path quality metrics as JSON.

Adapted from e2e-perf/venv_build_test.py: measures structural venv efficiency
rather than wall-clock timing. A high dupe_realpaths count or many distinct
site-packages roots indicates unnecessary overhead in the assembled venv.
"""

import json
import os
import sys
from pathlib import Path


def main() -> None:
    entries = [p for p in sys.path if p]
    sp_roots = {p for p in entries if "site-packages" in p}
    realpaths = [os.path.realpath(p) for p in entries]
    dupe_realpaths = len(realpaths) - len(set(realpaths))

    metrics = {
        "total_entries": len(entries),
        "distinct_sp_roots": len(sp_roots),
        "dupe_realpaths": dupe_realpaths,
    }

    out = sys.argv[1] if len(sys.argv) > 1 else None
    if out:
        Path(out).write_text(json.dumps(metrics))
    else:
        print(json.dumps(metrics))


if __name__ == "__main__":
    main()