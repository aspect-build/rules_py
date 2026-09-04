#!/usr/bin/env python3
"""Parse hyperfine JSON output for `bazel build --nobuild //...`, build a markdown
 table, and exit 1 on regression.

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


def write_gh_output(text: str) -> None:
    """Write to GITHUB_OUTPUT if available, so sticky PR comment always has content."""
    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as f:
            f.write("table\u003c\u003cEOF\n")
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
        "mean_ms": r["mean"] * 1000,
        "stddev_ms": (r["stddev"] or 0.0) * 1000,
        "min_ms": r["min"] * 1000,
        "max_ms": r["max"] * 1000,
        "median_ms": r["median"] * 1000,
        "n": len(r.get("times") or []) or 1,
    }


def noise_floor_pct(a: dict[str, Any], b: dict[str, Any]) -> float:
    """~95% noise band for the a→b delta, as a percentage of a's median.

    Two standard errors of the difference of means; deltas below this are
    indistinguishable from run-to-run noise.
    """
    if a["median_ms"] == 0:
        return 0.0
    se = math.sqrt(a["stddev_ms"] ** 2 / a["n"] + b["stddev_ms"] ** 2 / b["n"])
    return 2 * se / a["median_ms"] * 100


def load_auxiliary(path: str) -> dict[str, Any] | None:
    """Load optional auxiliary metrics JSON emitted by the benchmark harness."""
    p = Path(path)
    if not p.exists():
        return None
    with p.open() as f:
        return json.load(f)


def pct(a: float, b: float) -> float:
    """Percentage delta from a to b."""
    if a == 0:
        return 0.0
    return (b - a) / a * 100


def fmt(val: float) -> str:
    """Format milliseconds with sensible precision."""
    return f"{val:.1f}" if val < 10 else f"{val:.0f}"


def warn(delta: float) -> str:
    """Return warning emoji if delta exceeds threshold."""
    return "⚠️" if delta > THRESHOLD_REGRESSION_PCT else ""


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare analysis benchmark results")
    parser.add_argument("bcr", help="BCR hyperfine JSON")
    parser.add_argument("main", help="HEAD main hyperfine JSON")
    parser.add_argument("pr", help="PR hyperfine JSON")
    parser.add_argument(
        "--output-table",
        help="Write only the markdown table to this file instead of stdout",
    )
    args = parser.parse_args()

    bcr_path, main_path, pr_path = args.bcr, args.main, args.pr

    bcr = load_runtime(bcr_path)
    main = load_runtime(main_path)
    pr = load_runtime(pr_path)

    bcr_aux = load_auxiliary(bcr_path.replace(".json", "-aux.json"))
    main_aux = load_auxiliary(main_path.replace(".json", "-aux.json"))
    pr_aux = load_auxiliary(pr_path.replace(".json", "-aux.json"))

    main_vs_bcr = pct(bcr["median_ms"], main["median_ms"])
    pr_vs_bcr = pct(bcr["median_ms"], pr["median_ms"])
    pr_vs_main = pct(main["median_ms"], pr["median_ms"])
    noise_pct = noise_floor_pct(main, pr)

    has_aux = bcr_aux is not None or main_aux is not None or pr_aux is not None

    def aux_cells(aux: dict[str, Any] | None) -> list[str]:
        if aux is None:
            return ["—"] * 5
        targets = aux.get("targets")
        actions = aux.get("actions")
        cts = aux.get("configured_targets")
        ext = aux.get("external_configured_targets")
        cts_cell = f"{cts} ({ext})" if cts and ext is not None else str(cts or "—")
        # Configured-per-target rises with config fan-out (dep_groups,
        # python_version); actions-per-configured falls when the growth is
        # actionless nodes (alias chains).
        cts_per_target = f"{cts / targets:.1f}" if targets and cts else "—"
        actions_per_ct = f"{actions / cts:.2f}" if actions and cts else "—"
        return [str(targets or "—"), str(actions or "—"), cts_cell, cts_per_target, actions_per_ct]

    def make_row(
        label: str,
        d: dict[str, Any],
        vs_bcr: str,
        vs_main: str,
        aux: dict[str, Any] | None,
    ) -> list[str]:
        cells = [
            label,
            f"{fmt(d['mean_ms'])}/{fmt(d['median_ms'])} ±{fmt(d['stddev_ms'])}",
            vs_bcr,
            vs_main,
        ]
        if has_aux:
            cells += aux_cells(aux)
        return cells

    header = ["Version", "Time (ms)", "vs BCR", "vs main"]
    if has_aux:
        header += ["Targets", "Actions", "Configured (ext)", "Cfg/target", "Actions/cfg"]

    bcr_label = os.environ.get("ANALYSIS_BCR_VERSION", "release")
    rows = [
        header,
        make_row(f"BCR {bcr_label}", bcr, "—", "—", bcr_aux),
        make_row(
            "main",
            main,
            f"{main_vs_bcr:+.1f}% {warn(main_vs_bcr)}".strip(),
            "—",
            main_aux,
        ),
        make_row(
            "PR",
            pr,
            f"{pr_vs_bcr:+.1f}% {warn(pr_vs_bcr)}".strip(),
            f"{pr_vs_main:+.1f}% {warn(pr_vs_main)}".strip(),
            pr_aux,
        ),
    ]

    # GFM pipe table. NBSP inside cells removes wrap points; GitHub already
    # scrolls tables wider than the comment. Numeric columns right-aligned.
    def cell(c: str) -> str:
        return c.replace(" ", "\u00a0")

    table = "## Bazel analysis benchmark\n\n"
    table += "| " + " | ".join(cell(c) for c in header) + " |\n"
    table += "|" + "|".join(":---" if i == 0 else "---:" for i in range(len(header))) + "|\n"
    for r in rows[1:]:
        table += "| " + " | ".join(cell(c) for c in r) + " |\n"

    table += (
        f"\n> Measured with `hyperfine --warmup 1 --runs 10` on "
        f"`{os.environ.get('RUNNER_OS', 'local')}`\n"
    )
    table += (
        "> **Time** = mean/median ±stddev. **Cfg** = configured targets; "
        "(ext) = the count in external repos (the @pypi hub machinery).\n"
    )
    table += (
        f"> **Gate**: PR vs HEAD main median (threshold: {THRESHOLD_REGRESSION_PCT}%, "
        f"and must exceed the 2×SE noise floor, here {noise_pct:.1f}%). "
        f"BCR is shown only as a historical baseline.\n"
    )
    table += (
        "> **Command**: warm-server `bazel build --nobuild //workspace/...`, analysis cache "
        "discarded each run via a fresh `--action_env` value; no disk cache.\n"
    )

    write_gh_output(table)

    if args.output_table:
        Path(args.output_table).write_text(table)
    else:
        print(table)

    if pr_vs_main > THRESHOLD_REGRESSION_PCT and pr_vs_main > noise_pct:
        print(
            f"\n❌ REGRESSION: PR median is {pr_vs_main:.1f}% slower than HEAD main "
            f"(threshold: {THRESHOLD_REGRESSION_PCT}%, noise floor: {noise_pct:.1f}%)"
        )
        sys.exit(1)

    print(
        f"\n✅ No regression detected (PR median is {pr_vs_main:+.1f}% vs HEAD main; "
        f"noise floor {noise_pct:.1f}%)"
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
