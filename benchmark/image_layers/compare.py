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
import math
import os
import sys
from pathlib import Path
from typing import Any

THRESHOLD_REGRESSION_PCT = 10  # fail CI if PR is >10% slower than HEAD main

# (key, label, actions_field): analysis records the target's total action
# count from aquery; incrementals record actions re-executed, from BEP.
SCENARIOS = [
    ("analysis", "analysis", "actions_total"),
    ("inc-source", "1p source", "actions_executed"),
    ("inc-wheel", "3p wheel", "actions_executed"),
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
        "n": len(r.get("times") or []) or 1,
    }


def noise_floor_pct(a: dict[str, Any], b: dict[str, Any]) -> float:
    """~95% noise band for the a→b delta, as a percentage of a's median.

    Two standard errors of the difference of means; deltas below this are
    indistinguishable from run-to-run noise.
    """
    if a["median_s"] == 0:
        return 0.0
    se = math.sqrt(a["stddev_s"] ** 2 / a["n"] + b["stddev_s"] ** 2 / b["n"])
    return 2 * se / a["median_s"] * 100


def load_actions(prefix: str, scenario_key: str, field: str) -> int | None:
    """Load the action count for one variant/scenario, if recorded."""
    p = Path(f"{prefix}-{scenario_key}-actions.json")
    if not p.exists():
        print(f"WARNING: actions file not found: {p}", file=sys.stderr)
        return None
    with p.open() as f:
        return int(json.load(f)[field])


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

    header = ["Scenario", "Version", "Time (s)", "Actions", "vs BCR", "vs main"]
    rows: list[list[str]] = [header]

    regressions: list[tuple[str, float, float]] = []

    for scenario_key, scenario_label, actions_field in SCENARIOS:
        bcr = load_runtime(f"{args.bcr}-{scenario_key}.json")
        main = load_runtime(f"{args.main}-{scenario_key}.json")
        pr = load_runtime(f"{args.pr}-{scenario_key}.json")

        bcr_actions = load_actions(args.bcr, scenario_key, actions_field)
        main_actions = load_actions(args.main, scenario_key, actions_field)
        pr_actions = load_actions(args.pr, scenario_key, actions_field)

        main_vs_bcr = pct(bcr["median_s"], main["median_s"])
        pr_vs_bcr = pct(bcr["median_s"], pr["median_s"])
        pr_vs_main = pct(main["median_s"], pr["median_s"])
        noise_pct = noise_floor_pct(main, pr)

        def make_row(
            label: str, d: dict[str, Any], actions: str, vs_bcr: str, vs_main: str
        ) -> list[str]:
            return [
                scenario_label,
                label,
                f"{fmt(d['mean_s'])}/{fmt(d['median_s'])} ±{fmt(d['stddev_s'])}",
                actions,
                vs_bcr,
                vs_main,
            ]

        def actions_cell(actions: int | None) -> str:
            return "—" if actions is None else str(actions)

        pr_actions_cell = actions_cell(pr_actions)
        if pr_actions is not None and main_actions is not None and pr_actions > main_actions:
            pr_actions_cell += " ⚠️"

        rows.append(make_row(f"BCR {bcr_label}", bcr, actions_cell(bcr_actions), "—", "—"))
        rows.append(make_row(
            "main",
            main,
            actions_cell(main_actions),
            f"{main_vs_bcr:+.1f}% {warn(main_vs_bcr)}".strip(),
            "—",
        ))
        rows.append(make_row(
            "PR",
            pr,
            pr_actions_cell,
            f"{pr_vs_bcr:+.1f}% {warn(pr_vs_bcr)}".strip(),
            f"{pr_vs_main:+.1f}% {warn(pr_vs_main)}".strip(),
        ))

        if pr_vs_main > THRESHOLD_REGRESSION_PCT and pr_vs_main > noise_pct:
            regressions.append((scenario_label, pr_vs_main, noise_pct))

    # GFM pipe table. NBSP inside cells removes wrap points; GitHub already
    # scrolls tables wider than the comment. Numeric columns right-aligned.
    def cell(c: str) -> str:
        return c.replace(" ", "\u00a0")

    table = "## py_image_layer benchmark\n\n"
    table += "| " + " | ".join(cell(c) for c in header) + " |\n"
    table += "|" + "|".join(":---" if i < 2 else "---:" for i in range(len(header))) + "|\n"
    for r in rows[1:]:
        table += "| " + " | ".join(cell(c) for c in r) + " |\n"

    table += (
        "\n> **Time** = mean/median ±stddev.\n"
    )
    table += (
        f"> Measured with hyperfine on `{os.environ.get('RUNNER_OS', 'local')}`, "
        "building `//workspace:image_layers` (10 binaries, ~30-wheel dep pool, grouped "
        "first-party/pip/interpreter tier) with isolated output base, no disk cache.\n"
    )
    table += (
        "> **Scenarios**: analysis = warm-server `bazel build --nobuild`, re-analyzed each run "
        "via a fresh `--action_env` value; "
        "incrementals run against a built state with warm analysis: source = append to the last package's `lib.py`, "
        "wheel = rewrite click `post_install_patches` content.\n"
    )
    table += (
        "> **Actions**: for Analysis, the total action count behind the image target "
        "from `aquery deps(...)`; for incrementals, actions re-executed for the mutation, "
        "from a single instrumented "
        "run's BEP build metrics (deterministic; per-mnemonic breakdown in the "
        "`*-actions.json` artifacts). Informational only, not gated.\n"
    )
    table += (
        f"> **Gate**: PR vs HEAD main median per scenario (threshold: {THRESHOLD_REGRESSION_PCT}%, "
        "and must exceed the 2×SE noise floor). "
        "BCR is shown only as a historical baseline.\n"
    )

    write_gh_output(table)

    if args.output_table:
        Path(args.output_table).write_text(table)
    else:
        print(table)

    if regressions:
        for scenario_label, delta, noise in regressions:
            print(
                f"\n❌ REGRESSION [{scenario_label}]: PR median is {delta:.1f}% slower than HEAD main "
                f"(threshold: {THRESHOLD_REGRESSION_PCT}%, noise floor: {noise:.1f}%)"
            )
        sys.exit(1)

    print("\n✅ No regression detected in any build scenario")
    sys.exit(0)


if __name__ == "__main__":
    main()
