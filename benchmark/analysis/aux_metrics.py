#!/usr/bin/env python3
"""Assemble the benchmark aux-metrics JSON from saved bazel query outputs.

Usage: aux_metrics.py <query-targets.txt> <aquery-summary.txt> <cquery-deps.txt>

Emits targets, actions (with per-mnemonic breakdown), and configured-target
counts split into workspace vs external. The split isolates config fan-out of
the @pypi hub (dep_groups, python_version) from workspace-shape changes.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Assemble benchmark aux metrics JSON")
    parser.add_argument("targets", help="bazel query output listing workspace targets")
    parser.add_argument("aquery", help="bazel aquery --output=summary output")
    parser.add_argument("cquery", help="bazel cquery deps(...) output")
    parser.add_argument("--py-tests", help="bazel query output listing py_test targets")
    parser.add_argument("--test-files-per-package", type=int)
    parser.add_argument("--test-generation-mode")
    parser.add_argument("--dep-groups", default="")
    args = parser.parse_args()
    targets_path, aquery_path, cquery_path = args.targets, args.aquery, args.cquery

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

    metrics = {
        "targets": targets,
        "actions": actions,
        "configured_targets": workspace_cts + external_cts,
        "workspace_configured_targets": workspace_cts,
        "external_configured_targets": external_cts,
        "action_mnemonics": dict(sorted(mnemonics.items(), key=lambda kv: -kv[1])),
    }
    if args.py_tests:
        metrics["py_test_targets"] = sum(1 for line in Path(args.py_tests).open() if line.strip())
    if args.test_generation_mode:
        metrics["workload"] = {
            "test_files_per_package": args.test_files_per_package,
            "test_generation_mode": args.test_generation_mode,
            "dep_groups": args.dep_groups,
        }
    json.dump(
        metrics,
        sys.stdout,
        indent=1,
    )
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
