#!/usr/bin/env python3
"""Assemble the benchmark aux-metrics JSON from saved bazel query outputs.

Usage: aux_metrics.py <query-targets.txt> <aquery-summary.txt> <cquery-deps.txt>

Emits targets, actions (with per-mnemonic breakdown), and configured-target
counts split into workspace vs external. The split isolates config fan-out of
the @pypi hub (dep_groups, python_version) from workspace-shape changes.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def main() -> int:
    targets_path, aquery_path, cquery_path = sys.argv[1:4]

    targets = sum(1 for line in Path(targets_path).open() if line.strip())

    actions = 0
    mnemonics: dict[str, int] = {}
    in_mnemonics = False
    for line in Path(aquery_path).open():
        line = line.rstrip()
        total = re.match(r"^(\d+) total actions\.$", line)
        if total:
            actions = int(total.group(1))
        if line == "Mnemonics:":
            in_mnemonics = True
            continue
        if in_mnemonics:
            entry = re.match(r"^  (\S+): (\d+)$", line)
            if entry:
                mnemonics[entry.group(1)] = int(entry.group(2))
            else:
                in_mnemonics = False

    workspace_cts = 0
    external_cts = 0
    for line in Path(cquery_path).open():
        if line.startswith("//"):
            workspace_cts += 1
        elif line.startswith("@"):
            external_cts += 1

    if not targets or not actions or not workspace_cts:
        print("ERROR: empty metrics; a bazel query output is missing or malformed", file=sys.stderr)
        return 1

    json.dump(
        {
            "targets": targets,
            "actions": actions,
            "configured_targets": workspace_cts + external_cts,
            "workspace_configured_targets": workspace_cts,
            "external_configured_targets": external_cts,
            "action_mnemonics": dict(sorted(mnemonics.items(), key=lambda kv: -kv[1])),
        },
        sys.stdout,
        indent=1,
    )
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
