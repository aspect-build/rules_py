#!/usr/bin/env python3
"""Parse hyperfine JSON output, build a markdown table, exit 1 on regression.

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
    return f"{val:.1f}"


def fmt_s(val: float) -> str:
    """Format seconds with sensible precision."""
    return f"{val:.2f}"


def warn(delta: float) -> str:
    """Return warning emoji if delta exceeds threshold."""
    return "⚠️" if delta > THRESHOLD_REGRESSION_PCT else ""


def render_table(rows: list[list[str]], left_cols: int = 1) -> str:
    """GFM pipe table. NBSP inside cells removes wrap points; GitHub already
    scrolls tables wider than the comment. Numeric columns right-aligned."""

    def cell(c: str) -> str:
        return c.replace(" ", "\u00a0")

    n = len(rows[0])
    lines = ["| " + " | ".join(cell(c) for c in rows[0]) + " |"]
    lines.append("|" + "|".join(":---" if i < left_cols else "---:" for i in range(n)) + "|")
    lines += ["| " + " | ".join(cell(c) for c in r) + " |" for r in rows[1:]]
    return "\n".join(lines)


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

    main_vs_bcr = pct(bcr["median_ms"], main["median_ms"])
    pr_vs_bcr = pct(bcr["median_ms"], pr["median_ms"])
    pr_vs_main = pct(main["median_ms"], pr["median_ms"])
    noise_pct = noise_floor_pct(main, pr)

    has_build = bcr_build is not None or main_build is not None or pr_build is not None
    has_syspath = bcr_syspath is not None or main_syspath is not None or pr_syspath is not None

    def make_row(label: str, d: dict[str, Any], d_build: dict[str, float] | None, vs_bcr: str, vs_main: str) -> list[str]:
        cells = [
            label,
            f"{fmt(d['mean_ms'])}/{fmt(d['median_ms'])} ±{fmt(d['stddev_ms'])}",
            vs_bcr,
            vs_main,
        ]
        if has_build:
            cells.append(fmt_s(d_build["build_s"]) if d_build else "—")
        return cells

    header = ["Version", "Time (ms)", "vs BCR", "vs main"]
    if has_build:
        header.append("Build (s)")

    rows = [
        header,
        make_row("BCR 1.11.7", bcr, bcr_build, "—", "—"),
        make_row(
            "main", main, main_build,
            f"{main_vs_bcr:+.1f}% {warn(main_vs_bcr)}".strip(), "—"
        ),
        make_row(
            "PR", pr, pr_build,
            f"{pr_vs_bcr:+.1f}% {warn(pr_vs_bcr)}".strip(),
            f"{pr_vs_main:+.1f}% {warn(pr_vs_main)}".strip()
        ),
    ]

    table = "## py_binary startup benchmark\n\n"
    table += render_table(rows) + "\n"

    table += (
        "\n> **Time** = mean/median ±stddev.\n"
        f"> Measured with `hyperfine --warmup 5 --runs 50 --shell=none` on "
        f"`{os.environ.get('RUNNER_OS', 'local')}`\n"
    )
    table += (
        f"> **Gate**: PR vs HEAD main median (threshold: {THRESHOLD_REGRESSION_PCT}%, "
        f"and must exceed the 2×SE noise floor, here {noise_pct:.1f}%). "
        f"BCR is shown only as a historical baseline.\n"
    )
    if has_build:
        table += (
            "> **Build time**: cold `bazel build //:bench` with isolated output base, no disk cache; "
            "external repos prefetched so network is excluded.\n"
        )

    if has_syspath:
        table += "\n### sys.path quality\n\n"

        def syspath_row(label: str, sp: dict[str, int] | None) -> list[str]:
            if sp is None:
                return [label, "—", "—", "—"]
            dupe_flag = " ⚠️" if sp["dupe_realpaths"] > 0 else ""
            return [
                label,
                str(sp["total_entries"]),
                str(sp["distinct_sp_roots"]),
                f"{sp['dupe_realpaths']}{dupe_flag}",
            ]

        table += render_table([
            ["Version", "entries", "sp roots", "dupes"],
            syspath_row("BCR 1.11.7", bcr_syspath),
            syspath_row("main", main_syspath),
            syspath_row("PR", pr_syspath),
        ]) + "\n"
        table += (
            "\n> **sys.path quality** measured by `bench_syspath` inside the assembled venv: "
            "sys.path entries, distinct site-packages roots, duplicate realpaths. "
            "Duplicates indicate symlink redundancy; many roots suggest an inefficient venv layout.\n"
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
