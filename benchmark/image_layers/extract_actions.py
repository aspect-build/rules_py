#!/usr/bin/env python3
"""Extract executed-action counts from a Bazel BEP JSON file.

Emits {"actions_executed": N, "mnemonics": {mnemonic: count, ...}} on stdout.
"""

from __future__ import annotations

import json
import sys


def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <bep.json>", file=sys.stderr)
        sys.exit(2)

    metrics = None
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            if "buildMetrics" in event:
                metrics = event["buildMetrics"]

    if metrics is None:
        print(f"ERROR: no buildMetrics event in {sys.argv[1]}", file=sys.stderr)
        sys.exit(1)

    summary = metrics.get("actionSummary", {})
    # int64 fields serialize as strings in proto3 JSON
    mnemonics = {
        d["mnemonic"]: int(d.get("actionsExecuted", 0))
        for d in summary.get("actionData", [])
        if int(d.get("actionsExecuted", 0)) > 0
    }
    json.dump(
        {
            "actions_executed": int(summary.get("actionsExecuted", 0)),
            "mnemonics": dict(sorted(mnemonics.items(), key=lambda kv: -kv[1])),
        },
        sys.stdout,
    )
    print()


if __name__ == "__main__":
    main()
