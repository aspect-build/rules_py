#!/usr/bin/env python3
"""Unified benchmark results comparator.

Two subcommands, each gating PR vs HEAD main at THRESHOLD_REGRESSION_PCT:
  - analysis : profile_benchmark JSON (analysis_ms from runAnalysisPhase).
               Also renders the per-function Starlark CPU diagnostic section.
  - startup  : hyperfine runtime JSON for the fan-in //:bench py_binary.

BCR is shown as a historical baseline only (transitive dep versions drift
between releases, so gating against it is misleading). See tdr.md and
docs/superpowers/specs/*-design.md.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path
from typing import Any

THRESHOLD_REGRESSION_PCT = 10
EM = "\u2014"  # em dash; module constant so it can appear inside f-string expressions
TOTAL_SIGMA = 2.0
FN_SIGMA = 3.0
HOTSPOT_MIN_PCT = 1.0


def write_gh_output(text: str) -> None:
    """Write to GITHUB_OUTPUT if available, so the sticky PR comment always has content."""
    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as f:
            f.write("table<<EOF\n")
            f.write(text)
            f.write("EOF\n")


def pct(a: float, b: float) -> float:
    """Percentage delta from a to b."""
    if a == 0:
        return 0.0
    return (b - a) / a * 100


def fmt(val: float) -> str:
    return f"{val:.3f}"


def warn(delta: float) -> str:
    return "\u26a0\ufe0f" if delta > THRESHOLD_REGRESSION_PCT else ""


# --------------------------------------------------------------------------- #
# analysis subcommand
# --------------------------------------------------------------------------- #

def load_result(path: str) -> dict[str, Any]:
    """Load a profile_benchmark JSON result and validate the analysis_ms metric."""
    p = Path(path)
    if not p.exists():
        _fail(f"result file not found: {path}")
    with p.open() as f:
        data = json.load(f)
    if "analysis_ms" not in data:
        _fail(f"missing 'analysis_ms' in {path}")
    for key in ("mean", "median", "stddev"):
        if key not in data["analysis_ms"]:
            _fail(f"missing 'analysis_ms.{key}' in {path}")
    return data


def load_auxiliary(path: str) -> dict[str, Any] | None:
    """Load optional auxiliary metrics JSON emitted by the benchmark harness."""
    p = Path(path)
    if not p.exists():
        return None
    with p.open() as f:
        return json.load(f)


def is_regression(main_result: dict[str, Any], pr_result: dict[str, Any], threshold: float) -> bool:
    """True iff PR analysis mean is more than `threshold`% slower than main."""
    return pct(main_result["analysis_ms"]["mean"], pr_result["analysis_ms"]["mean"]) > threshold


def _short(name: str, limit: int = 48) -> str:
    """Shorten verbose pprof function names (e.g. MODULE.bazel URLs)."""
    if "MODULE.bazel" in name and "/" in name:
        name = name.rsplit("/", 1)[-1]
    if len(name) > limit:
        name = name[: limit - 1] + "\u2026"
    return name


def _starlark_section(main_result: dict[str, Any], pr_result: dict[str, Any]) -> str:
    """Diagnostic Starlark CPU diff (PR vs main). Informational, not a gate.

    Two layers of noise control so the section stays quiet on a no-op PR:
      - Total-level gate: only render the movers table when the PR's total
        Starlark CPU is significantly above main's (TOTAL_SIGMA). The total
        aggregates every sample, so its variance is small and the test is
        robust without the multiple-comparisons problem.
      - Per-function flagging: a mover is only marked significant when its delta
        exceeds FN_SIGMA * combined stderr, surviving ~100 comparisons.
    Hotspots (big, stable functions) are always shown.
    """
    main_sf = main_result.get("starlark_fn")
    pr_sf = pr_result.get("starlark_fn")
    if not isinstance(main_sf, dict) or not isinstance(pr_sf, dict):
        return ""  # missing or old (pre-stddev) schema -- can't do significance

    main_total = main_sf.get("total", {})
    pr_total = pr_sf.get("total", {})
    main_fns = {r["name"]: r for r in main_sf.get("functions", [])}
    pr_fns = {r["name"]: r for r in pr_sf.get("functions", [])}

    runs = main_total.get("runs") or pr_total.get("runs") or 1
    n = max(runs, 1)

    def combined_se(m_std: float, p_std: float) -> float:
        # Standard error of the difference of two independent means: each side
        # contributes stddev/sqrt(n). Buggy /(n) would shrink the noise band
        # ~sqrt(n)x and flag sampling jitter as significant.
        sn = math.sqrt(n)
        return math.sqrt((m_std / sn) ** 2 + (p_std / sn) ** 2)

    total_se = combined_se(main_total.get("stddev_ms", 0.0), pr_total.get("stddev_ms", 0.0))
    main_total_ms = main_total.get("mean_ms", 0.0)
    pr_total_ms = pr_total.get("mean_ms", 0.0)
    delta_total = pr_total_ms - main_total_ms
    pct_total = pct(main_total_ms, pr_total_ms) if main_total_ms else 0.0
    total_significant = total_se > 0 and delta_total > TOTAL_SIGMA * total_se

    out = "\n### \U0001f50d Starlark CPU \u2014 where the problem is (PR vs main)\n\n"
    out += (
        f"**Total Starlark CPU:** main {main_total_ms:.0f} ms, PR {pr_total_ms:.0f} ms "
        f"(\u0394 {delta_total:+.0f} ms, {pct_total:+.1f}%, "
        f"\u00b1{total_se:.0f} ms stderr over {runs} runs).\n\n"
    )

    if not total_significant:
        out += (
            "\u2705 **No significant Starlark CPU change** \u2014 the total is within "
            "run-to-run noise, so per-function deltas are hidden (they are sampling "
            "jitter, not signal).\n"
        )
    else:
        movers = []
        for name, pr_r in pr_fns.items():
            m_r = main_fns.get(name)
            m_ms = m_r["mean_ms"] if m_r else 0.0
            d = pr_r["mean_ms"] - m_ms
            if d <= 0:
                continue
            se = combined_se(m_r.get("stddev_ms", 0.0) if m_r else 0.0, pr_r.get("stddev_ms", 0.0))
            movers.append((name, m_ms, pr_r["mean_ms"], d, se))
        movers.sort(key=lambda x: x[3], reverse=True)

        out += "**Top movers (candidates, \u0394 > 3\u03c3 marked):**\n\n"
        out += "| Function | main ms | PR ms | \u0394 ms | \u00b1 stderr | \u0394 % |\n|---|---|---|---|---|---|\n"
        for name, m_ms, pr_ms, d, se in movers[:10]:
            if m_ms > 0:
                dpct = f"+{d / m_ms * 100:.0f}%"
            else:
                dpct = "new"
            flag = " \u26a0\ufe0f" if (se > 0 and d > FN_SIGMA * se) else ""
            out += (
                f"| `{_short(name)}` | {m_ms:.1f} | {pr_ms:.1f} | "
                f"+{d:.1f} | \u00b1{se:.1f} | {dpct}{flag} |\n"
            )

    hot = [r for r in pr_fns.values() if r.get("pct", 0.0) >= HOTSPOT_MIN_PCT][:10]
    if hot:
        out += "\n**Top by absolute time (PR):**\n\n"
        out += "| Function | PR ms | % of total |\n|---|---|---|\n"
        for r in hot:
            out += f"| `{_short(r['name'])}` | {r['mean_ms']:.1f} | {r.get('pct', 0.0):.1f}% |\n"

    out += (
        "\n> Sample-based attribution (Starlark CPU across the whole `--nobuild` run: "
        "bzlmod loading + analysis). Significance is run-to-run stderr \u00d7 sigma; "
        "builtins are attributed to the caller.\n"
    )
    return out


def run_analysis(args: argparse.Namespace) -> int:
    bcr_path, main_path, pr_path = args.bcr, args.main, args.pr

    bcr = load_result(bcr_path)
    main = load_result(main_path)
    pr = load_result(pr_path)

    bcr_aux = load_auxiliary(bcr_path.replace(".json", "-aux.json"))
    main_aux = load_auxiliary(main_path.replace(".json", "-aux.json"))
    pr_aux = load_auxiliary(pr_path.replace(".json", "-aux.json"))

    main_vs_bcr = pct(bcr["analysis_ms"]["mean"], main["analysis_ms"]["mean"])
    pr_vs_bcr = pct(bcr["analysis_ms"]["mean"], pr["analysis_ms"]["mean"])
    pr_vs_main = pct(main["analysis_ms"]["mean"], pr["analysis_ms"]["mean"])

    has_aux = bcr_aux is not None or main_aux is not None or pr_aux is not None

    table = "## Bazel analysis benchmark\n\n"
    table += "| Version | Analysis (ms) | Median (ms) | \u00b1 stddev | Wall (ms) | vs BCR | vs main | Packages | Targets |\n"
    table += "|---------|--------------|-------------|----------|----------|--------|---------|----------|----------|\n"

    def aux_cell(aux: dict[str, Any] | None) -> str:
        if aux is None:
            return f"{EM} | {EM}"
        return f"{aux.get('packages', EM)} | {aux.get('targets', EM)}"

    def row(label: str, d: dict[str, Any], vs_bcr: str, vs_main: str, aux: dict[str, Any] | None) -> str:
        a = d["analysis_ms"]
        wall = d.get("wall_ms", {}).get("mean")
        wall_str = fmt(wall) if wall is not None else EM
        return (
            f"| {label} | {fmt(a['mean'])} | {fmt(a['median'])} | "
            f"\u00b1{fmt(a['stddev'])} | {wall_str} | {vs_bcr} | {vs_main} | {aux_cell(aux)} |\n"
        )

    table += row("BCR 2.0.0-alpha.4 (baseline)", bcr, EM, EM, bcr_aux)
    table += row("HEAD main", main, f"{main_vs_bcr:+.1f}% {warn(main_vs_bcr)}", EM, main_aux)
    table += row("This PR", pr, f"{pr_vs_bcr:+.1f}% {warn(pr_vs_bcr)}",
                 f"{pr_vs_main:+.1f}% {warn(pr_vs_main)}", pr_aux)

    table += (
        f"\n> Analysis phase (`runAnalysisPhase`) extracted from `--profile` "
        f"on `{os.environ.get('RUNNER_OS', 'local')}`\n"
    )
    table += (
        f"> **Gate**: analysis_ms, PR vs HEAD main (threshold: {THRESHOLD_REGRESSION_PCT}%). "
        f"Wall time is informational (JVM/IO overhead). BCR is a historical baseline only.\n"
    )
    table += _starlark_section(main, pr)

    _emit(table, args.output_table)

    if is_regression(main, pr, THRESHOLD_REGRESSION_PCT):
        print(f"\n\u274c REGRESSION: PR analysis is {pr_vs_main:.1f}% slower than HEAD main "
              f"(threshold: {THRESHOLD_REGRESSION_PCT}%)")
        return 1
    print(f"\n\u2705 No regression detected (PR analysis is {pr_vs_main:+.1f}% vs HEAD main)")
    return 0


# --------------------------------------------------------------------------- #
# startup subcommand
# --------------------------------------------------------------------------- #

def load_runtime(path: str) -> dict[str, Any]:
    """Load a single hyperfine runtime JSON result."""
    p = Path(path)
    if not p.exists():
        _fail(f"result file not found: {path}")
    with p.open() as f:
        data = json.load(f)
    if "results" not in data or not data["results"]:
        _fail(f"no results in {path}")
    r = data["results"][0]
    for key in ("mean", "stddev", "min", "max", "median"):
        if key not in r:
            _fail(f"missing '{key}' in {path}")
    return {
        "mean_ms": r["mean"] * 1000,
        "stddev_ms": r["stddev"] * 1000,
        "min_ms": r["min"] * 1000,
        "max_ms": r["max"] * 1000,
        "median_ms": r["median"] * 1000,
    }


def load_syspath(path: str) -> dict[str, int] | None:
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


def run_startup(args: argparse.Namespace) -> int:
    bcr_path, main_path, pr_path = args.bcr, args.main, args.pr

    bcr = load_runtime(bcr_path)
    main = load_runtime(main_path)
    pr = load_runtime(pr_path)

    bcr_syspath = load_syspath(bcr_path.replace(".json", "-syspath.json"))
    main_syspath = load_syspath(main_path.replace(".json", "-syspath.json"))
    pr_syspath = load_syspath(pr_path.replace(".json", "-syspath.json"))

    rt_main_vs_bcr = pct(bcr["mean_ms"], main["mean_ms"])
    rt_pr_vs_bcr = pct(bcr["mean_ms"], pr["mean_ms"])
    rt_pr_vs_main = pct(main["mean_ms"], pr["mean_ms"])

    has_syspath = bcr_syspath is not None or main_syspath is not None or pr_syspath is not None

    table = "## py_binary startup benchmark\n\n"
    table += "| Version | Startup (ms) | Median (ms) | \u00b1 stddev | vs BCR | vs main |\n"
    table += "|---------|-------------|-------------|----------|--------|---------|\n"

    def row(label: str, d: dict[str, Any], vs_bcr: str, vs_main: str) -> str:
        return (
            f"| {label} | {fmt(d['mean_ms'])} | {fmt(d['median_ms'])} | "
            f"\u00b1{fmt(d['stddev_ms'])} | {vs_bcr} | {vs_main} |\n"
        )

    table += row("BCR 2.0.0-alpha.4 (baseline)", bcr, EM, EM)
    table += row("HEAD main", main, f"{rt_main_vs_bcr:+.1f}% {warn(rt_main_vs_bcr)}", EM)
    table += row("This PR", pr, f"{rt_pr_vs_bcr:+.1f}% {warn(rt_pr_vs_bcr)}",
                 f"{rt_pr_vs_main:+.1f}% {warn(rt_pr_vs_main)}")

    table += (
        f"\n> Startup measured with `hyperfine --warmup 5 --runs 50` on "
        f"`{os.environ.get('RUNNER_OS', 'local')}`. Target: fan-in `//:bench` "
        f"(venv scales with --packages).\n"
    )
    table += (
        f"> **Gate** (threshold {THRESHOLD_REGRESSION_PCT}%, PR vs HEAD main): "
        "startup mean. BCR is a historical baseline only.\n"
    )

    if has_syspath:
        table += "\n### sys.path quality\n\n"
        table += "| Version | sys.path entries | distinct site-packages roots | duplicate realpaths |\n"
        table += "|---------|-----------------|------------------------------|---------------------|\n"

        def syspath_row(label: str, sp: dict[str, int] | None) -> str:
            if sp is None:
                return f"| {label} | {EM} | {EM} | {EM} |\n"
            dupe_flag = " \u26a0\ufe0f" if sp["dupe_realpaths"] > 0 else ""
            return (
                f"| {label} | {sp['total_entries']} | {sp['distinct_sp_roots']} "
                f"| {sp['dupe_realpaths']}{dupe_flag} |\n"
            )

        table += syspath_row("BCR 2.0.0-alpha.4 (baseline)", bcr_syspath)
        table += syspath_row("HEAD main", main_syspath)
        table += syspath_row("This PR", pr_syspath)
        table += (
            "\n> **sys.path quality** measured by `bench_main.py` inside the assembled venv. "
            "Duplicate realpaths indicate symlink redundancy; many distinct site-packages roots "
            "suggest an inefficient venv layout.\n"
        )

    _emit(table, args.output_table)

    if rt_pr_vs_main > THRESHOLD_REGRESSION_PCT:
        print(f"\n\u274c REGRESSION: startup {rt_pr_vs_main:.1f}% slower than HEAD main "
              f"(threshold: {THRESHOLD_REGRESSION_PCT}%)")
        return 1
    print(f"\n\u2705 No regression (startup {rt_pr_vs_main:+.1f}% vs HEAD main)")
    return 0


# --------------------------------------------------------------------------- #
# shared plumbing
# --------------------------------------------------------------------------- #

def _fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    write_gh_output(f"\u274c ERROR: {msg}")
    sys.exit(2)


def _emit(table: str, output_table: str | None) -> None:
    write_gh_output(table)
    if output_table:
        Path(output_table).write_text(table)
    else:
        print(table)


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare benchmark results (analysis | startup)")
    sub = parser.add_subparsers(dest="kind", required=True)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("bcr", help="BCR result JSON")
        p.add_argument("main", help="HEAD main result JSON")
        p.add_argument("pr", help="PR result JSON")
        p.add_argument("--output-table", help="write only the markdown table to this file")

    add_common(sub.add_parser("analysis", help="analysis_ms gate + Starlark CPU diagnostic"))
    add_common(sub.add_parser("startup", help="runtime gate + sys.path quality"))
    args = parser.parse_args()

    rc = run_analysis(args) if args.kind == "analysis" else run_startup(args)
    sys.exit(rc)


if __name__ == "__main__":
    main()
