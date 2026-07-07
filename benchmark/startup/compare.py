#!/usr/bin/env python3
"""Parse hyperfine JSON output, build a markdown table, exit 1 on regression.

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
        "mean_ms": r["mean"] * 1000,
        "stddev_ms": r["stddev"] * 1000,
        "min_ms": r["min"] * 1000,
        "max_ms": r["max"] * 1000,
        "median_ms": r["median"] * 1000,
    }


def load_build(path: str) -> dict[str, float] | None:
    """Load an optional build-time JSON ({build_ms: int})."""
    p = Path(path)
    if not p.exists():
        return None
    with p.open() as f:
        data = json.load(f)
    ms = data.get("build_ms", 0)
    return {"build_s": ms / 1000.0}


def load_syspath(path: str) -> dict[str, int] | None:
    """Load an optional sys.path quality JSON from syspath_probe.py."""
    p = Path(path)
    if not p.exists():
        return None
    with p.open() as f:
        data = json.load(f)
    return {
        "total_entries": data.get("total_entries", 0),
        "distinct_sp_roots": data.get("distinct_sp_roots", 0),
        "dupe_realpaths": data.get("dupe_realpaths", 0),
    }


def pct(a: float, b: float) -> float:
    """Percentage delta from a to b."""
    if a == 0:
        return 0.0
    return (b - a) / a * 100


def fmt(val: float) -> str:
    """Format milliseconds with sensible precision."""
    return f"{val:.3f}"


def fmt_s(val: float) -> str:
    """Format seconds with sensible precision."""
    return f"{val:.2f}"


def warn(delta: float) -> str:
    """Return warning emoji if delta exceeds threshold."""
    return "⚠️" if delta > THRESHOLD_REGRESSION_PCT else ""


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare startup benchmark results")
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

    bcr_build = load_build(bcr_path.replace(".json", "-build.json"))
    main_build = load_build(main_path.replace(".json", "-build.json"))
    pr_build = load_build(pr_path.replace(".json", "-build.json"))

    bcr_syspath = load_syspath(bcr_path.replace(".json", "-syspath.json"))
    main_syspath = load_syspath(main_path.replace(".json", "-syspath.json"))
    pr_syspath = load_syspath(pr_path.replace(".json", "-syspath.json"))

    main_vs_bcr = pct(bcr["mean_ms"], main["mean_ms"])
    pr_vs_bcr = pct(bcr["mean_ms"], pr["mean_ms"])
    pr_vs_main = pct(main["mean_ms"], pr["mean_ms"])

    has_build = bcr_build is not None or main_build is not None or pr_build is not None
    has_syspath = bcr_syspath is not None or main_syspath is not None or pr_syspath is not None

    table = "## py_binary startup benchmark\n\n"
    if has_build:
        table += "| Version | Mean (ms) | Median (ms) | ± stddev | vs BCR | vs main | Build (s) |\n"
        table += "|---------|-----------|-------------|----------|--------|---------|-----------|\n"
    else:
        table += "| Version | Mean (ms) | Median (ms) | ± stddev | vs BCR | vs main |\n"
        table += "|---------|-----------|-------------|----------|--------|---------|\n"

    def row(label: str, d: dict[str, Any], d_build: dict[str, float] | None, vs_bcr: str, vs_main: str) -> str:
        line = (
            f"| {label} | {fmt(d['mean_ms'])} | {fmt(d['median_ms'])} | "
            f"±{fmt(d['stddev_ms'])} | {vs_bcr} | {vs_main}"
        )
        if has_build:
            b = fmt_s(d_build["build_s"]) if d_build else "—"
            line += f" | {b}"
        line += " |\n"
        return line

    table += row(
        "BCR 1.11.7 (baseline)", bcr, bcr_build, "—", "—"
    )
    table += row(
        "HEAD main", main, main_build,
        f"{main_vs_bcr:+.1f}% {warn(main_vs_bcr)}", "—"
    )
    table += row(
        "This PR", pr, pr_build,
        f"{pr_vs_bcr:+.1f}% {warn(pr_vs_bcr)}",
        f"{pr_vs_main:+.1f}% {warn(pr_vs_main)}"
    )

    table += (
        f"\n> Measured with `hyperfine --warmup 5 --runs 50` on "
        f"`{os.environ.get('RUNNER_OS', 'local')}`\n"
    )
    table += (
        f"> **Gate**: PR vs HEAD main (threshold: {THRESHOLD_REGRESSION_PCT}%). "
        f"BCR is shown only as a historical baseline.\n"
    )
    if has_build:
        table += (
            "> **Build time**: cold `bazel build //:bench` with isolated output base, no disk cache.\n"
        )

    if has_syspath:
        table += "\n### sys.path quality\n\n"
        table += "| Version | sys.path entries | distinct site-packages roots | duplicate realpaths |\n"
        table += "|---------|-----------------|------------------------------|---------------------|\n"

        def syspath_row(label: str, sp: dict[str, int] | None) -> str:
            if sp is None:
                return f"| {label} | — | — | — |\n"
            dupe_flag = " ⚠️" if sp["dupe_realpaths"] > 0 else ""
            return (
                f"| {label} | {sp['total_entries']} | {sp['distinct_sp_roots']} "
                f"| {sp['dupe_realpaths']}{dupe_flag} |\n"
            )

        table += syspath_row("BCR 1.11.7 (baseline)", bcr_syspath)
        table += syspath_row("HEAD main", main_syspath)
        table += syspath_row("This PR", pr_syspath)
        table += (
            "\n> **sys.path quality** measured by `bench_syspath` inside the assembled venv. "
            "Duplicate realpaths indicate symlink redundancy; many distinct site-packages roots "
            "suggest an inefficient venv layout.\n"
        )

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
