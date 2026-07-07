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
        "stddev_ms": r["stddev"] * 1000,
        "min_ms": r["min"] * 1000,
        "max_ms": r["max"] * 1000,
        "median_ms": r["median"] * 1000,
    }


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
    return f"{val:.3f}"


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

    main_vs_bcr = pct(bcr["mean_ms"], main["mean_ms"])
    pr_vs_bcr = pct(bcr["mean_ms"], pr["mean_ms"])
    pr_vs_main = pct(main["mean_ms"], pr["mean_ms"])

    has_aux = bcr_aux is not None or main_aux is not None or pr_aux is not None

    table = "## Bazel analysis benchmark\n\n"
    if has_aux:
        table += "| Version | Mean (ms) | Median (ms) | ± stddev | vs BCR | vs main | Packages | Targets |\n"
        table += "|---------|-----------|-------------|----------|--------|---------|----------|----------|\n"
    else:
        table += "| Version | Mean (ms) | Median (ms) | ± stddev | vs BCR | vs main |\n"
        table += "|---------|-----------|-------------|----------|--------|---------|\n"

    def aux_cell(aux: dict[str, Any] | None) -> str:
        if aux is None:
            return "— | —"
        packages = aux.get("packages", "—")
        targets = aux.get("targets", "—")
        return f"{packages} | {targets}"

    def row(
        label: str,
        d: dict[str, Any],
        vs_bcr: str,
        vs_main: str,
        aux: dict[str, Any] | None,
    ) -> str:
        line = (
            f"| {label} | {fmt(d['mean_ms'])} | {fmt(d['median_ms'])} | "
            f"±{fmt(d['stddev_ms'])} | {vs_bcr} | {vs_main}"
        )
        if has_aux:
            line += f" | {aux_cell(aux)}"
        line += " |\n"
        return line

    table += row(
        "BCR 2.0.0-alpha.4 (baseline)", bcr, "—", "—", bcr_aux
    )
    table += row(
        "HEAD main",
        main,
        f"{main_vs_bcr:+.1f}% {warn(main_vs_bcr)}",
        "—",
        main_aux,
    )
    table += row(
        "This PR",
        pr,
        f"{pr_vs_bcr:+.1f}% {warn(pr_vs_bcr)}",
        f"{pr_vs_main:+.1f}% {warn(pr_vs_main)}",
        pr_aux,
    )

    table += (
        f"\n> Measured with `hyperfine --warmup 1 --runs 10` on "
        f"`{os.environ.get('RUNNER_OS', 'local')}`\n"
    )
    table += (
        f"> **Gate**: PR vs HEAD main (threshold: {THRESHOLD_REGRESSION_PCT}%). "
        f"BCR is shown only as a historical baseline.\n"
    )
    table += (
        "> **Command**: cold `bazel build --nobuild //workspace/...` with isolated output base, "
        "no disk cache.\n"
    )

    if has_aux:
        table += (
            "\n### Auxiliary metrics\n\n"
            "| Version | Loaded packages | Configured targets |\n"
            "|---------|-----------------|---------------------|\n"
        )

        def aux_row(label: str, aux: dict[str, Any] | None) -> str:
            if aux is None:
                return f"| {label} | — | — |\n"
            return f"| {label} | {aux.get('packages', '—')} | {aux.get('targets', '—')} |\n"

        table += aux_row("BCR 2.0.0-alpha.4 (baseline)", bcr_aux)
        table += aux_row("HEAD main", main_aux)
        table += aux_row("This PR", pr_aux)

    write_gh_output(table)

    if args.output_table:
        Path(args.output_table).write_text(table)
    else:
        print(table)

    if pr_vs_main > THRESHOLD_REGRESSION_PCT:
        print(
            f"\n❌ REGRESSION: PR is {pr_vs_main:.1f}% slower than HEAD main "
            f"(threshold: {THRESHOLD_REGRESSION_PCT}%)"
        )
        sys.exit(1)

    print(f"\n✅ No regression detected (PR is {pr_vs_main:+.1f}% vs HEAD main)")
    sys.exit(0)


if __name__ == "__main__":
    main()
