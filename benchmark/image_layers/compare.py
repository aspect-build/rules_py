#!/usr/bin/env python3
"""Parse hyperfine JSON output for the py_image_layer benchmark, build a
markdown table, and exit 1 on regression.

Each variant (bcr / main / pr) is measured under three scenarios:
  - analysis:   warm-server `bazel build --nobuild` of //workspace:image_layers,
                re-analyzed each run via a fresh --action_env value
  - inc-source: incremental rebuild after a first-party source change
  - inc-wheel:  incremental rebuild after a third-party wheel change

The regression gate compares PR against HEAD main (not BCR).
BCR is kept as a historical baseline for context, but gating against it is
misleading because transitive dependency versions drift between releases.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

THRESHOLD_REGRESSION_PCT = 10  # fail CI if PR is >10% slower than HEAD main

# (key, label, has_actions): analysis runs --nobuild, so no executed actions
SCENARIOS = [
    ("analysis", "Analysis", False),
    ("inc-source", "1p Source Change", True),
    ("inc-wheel", "3p Source Change", True),
]


def write_gh_output(text: str) -> None:
    """Write to GITHUB_OUTPUT if available, so sticky PR comment always has content."""
    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as f:
            f.write("table<<EOF\n")
            f.write(text)
            f.write("EOF\n")


def load_runtime(path: str) -> dict[str, Any]:
    """Load a single hyperfine JSON result."""
    p = Path(path)
    if not p.exists():
        msg = f"ERROR: result file not found: {path}"
        print(msg, file=sys.stderr)
        write_gh_output(f"❌ {msg}")
        sys.exit(2)

    with p.open() as f:
        data = json.load(f)

    if "results" not in data or not data["results"]:
        msg = f"ERROR: no results in {path}"
        print(msg, file=sys.stderr)
        write_gh_output(f"❌ {msg}")
        sys.exit(2)

    r = data["results"][0]
    for key in ("mean", "stddev", "min", "max", "median"):
        if key not in r:
            msg = f"ERROR: missing '{key}' in {path}"
            print(msg, file=sys.stderr)
            write_gh_output(f"❌ {msg}")
            sys.exit(2)

    return {
        "mean_s": r["mean"],
        # hyperfine reports null stddev for single-run results
        "stddev_s": r["stddev"] or 0.0,
        "min_s": r["min"],
        "max_s": r["max"],
        "median_s": r["median"],
    }


def load_actions(prefix: str, scenario_key: str) -> int | None:
    """Load the executed-action count for one variant/scenario, if recorded."""
    p = Path(f"{prefix}-{scenario_key}-actions.json")
    if not p.exists():
        print(f"WARNING: actions file not found: {p}", file=sys.stderr)
        return None
    with p.open() as f:
        return int(json.load(f)["actions_executed"])


def pct(a: float, b: float) -> float:
    """Percentage delta from a to b."""
    if a == 0:
        return 0.0
    return (b - a) / a * 100


def fmt(val: float) -> str:
    """Format seconds with sensible precision."""
    return f"{val:.2f}"


def warn(delta: float) -> str:
    """Return warning emoji if delta exceeds threshold."""
    return "⚠️" if delta > THRESHOLD_REGRESSION_PCT else ""


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare py_image_layer benchmark results")
    parser.add_argument("bcr", help="BCR result file prefix (loads <prefix>-<scenario>.json)")
    parser.add_argument("main", help="HEAD main result file prefix")
    parser.add_argument("pr", help="PR result file prefix")
    parser.add_argument(
        "--output-table",
        help="Write only the markdown table to this file instead of stdout",
    )
    args = parser.parse_args()

    bcr_label = os.environ.get("ANALYSIS_BCR_VERSION", "release")

    table = "## py_image_layer benchmark\n\n"
    table += "| Scenario | Version | Mean (s) | Median (s) | ± stddev | Actions | vs BCR | vs main |\n"
    table += "|----------|---------|----------|------------|----------|---------|--------|---------|\n"

    regressions: list[tuple[str, float]] = []

    for scenario_key, scenario_label, has_actions in SCENARIOS:
        bcr = load_runtime(f"{args.bcr}-{scenario_key}.json")
        main = load_runtime(f"{args.main}-{scenario_key}.json")
        pr = load_runtime(f"{args.pr}-{scenario_key}.json")

        bcr_actions = load_actions(args.bcr, scenario_key) if has_actions else None
        main_actions = load_actions(args.main, scenario_key) if has_actions else None
        pr_actions = load_actions(args.pr, scenario_key) if has_actions else None

        main_vs_bcr = pct(bcr["mean_s"], main["mean_s"])
        pr_vs_bcr = pct(bcr["mean_s"], pr["mean_s"])
        pr_vs_main = pct(main["mean_s"], pr["mean_s"])

        def row(
            label: str, d: dict[str, Any], actions: str, vs_bcr: str, vs_main: str
        ) -> str:
            return (
                f"| {scenario_label} | {label} | {fmt(d['mean_s'])} | {fmt(d['median_s'])} | "
                f"±{fmt(d['stddev_s'])} | {actions} | {vs_bcr} | {vs_main} |\n"
            )

        def actions_cell(actions: int | None) -> str:
            return "—" if actions is None else str(actions)

        pr_actions_cell = actions_cell(pr_actions)
        if pr_actions is not None and main_actions is not None and pr_actions > main_actions:
            pr_actions_cell += " ⚠️"

        table += row(f"BCR {bcr_label} (baseline)", bcr, actions_cell(bcr_actions), "—", "—")
        table += row(
            "HEAD main",
            main,
            actions_cell(main_actions),
            f"{main_vs_bcr:+.1f}% {warn(main_vs_bcr)}",
            "—",
        )
        table += row(
            "This PR",
            pr,
            pr_actions_cell,
            f"{pr_vs_bcr:+.1f}% {warn(pr_vs_bcr)}",
            f"{pr_vs_main:+.1f}% {warn(pr_vs_main)}",
        )

        if pr_vs_main > THRESHOLD_REGRESSION_PCT:
            regressions.append((scenario_label, pr_vs_main))

    table += (
        f"\n> Measured with hyperfine on `{os.environ.get('RUNNER_OS', 'local')}`, "
        "building `//workspace:image_layers` (5 binaries, small dep pool) with isolated output base, no disk cache.\n"
    )
    table += (
        "> **Scenarios**: analysis = warm-server `bazel build --nobuild`, re-analyzed each run "
        "via a fresh `--action_env` value; "
        "incrementals run against a built state with warm analysis: source = append to the last package's `lib.py`, "
        "wheel = rewrite click `post_install_patches` content.\n"
    )
    table += (
        "> **Actions**: actions re-executed for the mutation, from a single instrumented "
        "run's BEP build metrics (deterministic; per-mnemonic breakdown in the "
        "`*-actions.json` artifacts). Informational only, not gated.\n"
    )
    table += (
        f"> **Gate**: PR vs HEAD main (threshold: {THRESHOLD_REGRESSION_PCT}%). "
        "BCR is shown only as a historical baseline.\n"
    )

    write_gh_output(table)

    if args.output_table:
        Path(args.output_table).write_text(table)
    else:
        print(table)

    if regressions:
        for scenario_label, delta in regressions:
            print(
                f"\n❌ REGRESSION [{scenario_label}]: PR is {delta:.1f}% slower than HEAD main "
                f"(threshold: {THRESHOLD_REGRESSION_PCT}%)"
            )
        sys.exit(1)

    print("\n✅ No regression detected in any build scenario")
    sys.exit(0)


if __name__ == "__main__":
    main()
