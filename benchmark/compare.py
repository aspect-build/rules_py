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


def _combined_se(m_std: float, m_n: int, p_std: float, p_n: int) -> float:
    """Std error of (PR_mean - main_mean) for independent means with possibly
    unequal run counts: sqrt(m_std^2/m_n + p_std^2/p_n). Per-side n matters --
    profile_benchmark only appends non-empty decoded profiles, so main and PR can
    have different usable Starlark run counts.
    """
    return math.sqrt((m_std ** 2) / max(m_n, 1) + (p_std ** 2) / max(p_n, 1))


def _is_significant(delta: float, se: float) -> bool:
    """A positive delta that exceeds the noise band.

    stderr == 0 with delta > 0 is significant: a deterministic regression is
    real signal, not 'unknown' (the earlier `se > 0 and ...` guard hid it).
    """
    return delta > 0 and (se == 0 or delta > FN_SIGMA * se)


# --------------------------------------------------------------------------- #
# analysis subcommand
# --------------------------------------------------------------------------- #

def load_result(path: str, missing_ok: bool = False) -> dict[str, Any]:
    """Load a profile_benchmark JSON result and validate the analysis_ms metric."""
    p = Path(path)
    if not p.exists():
        if missing_ok:
            return {"_pending": True}
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


# Top-level dirs in the rules_py repo; used to reduce noisy pprof file paths
# (external repo or absolute checkout paths) to a repo-relative, clickable path.
_RULES_PY_ROOTS = ("py/", "uv/", "docs/", "e2e/", "examples/", "tools/")


def _relpath(file: str | None, limit: int = 56) -> str:
    """Reduce a pprof source file to something locatable.

    <builtin> -> "builtin"; a bzlmod MODULE.bazel URL -> "bzlmod"; otherwise try
    to find a rules_py top-level dir and return from there (works for both the
    bzlmod external path and an absolute local-checkout path).
    """
    if not file or file in ("<unknown>", ""):
        return ""
    if file == "<builtin>":
        return "builtin"
    if file.startswith("http"):
        return "bzlmod"
    for root in _RULES_PY_ROOTS:
        idx = file.find("/" + root)
        if idx != -1:
            rel = file[idx + 1:]
            return rel if len(rel) <= limit else rel[: limit - 1] + "\u2026"
    if "/external/" in file:
        after = file.split("/external/", 1)[1]
        parts = after.split("/", 1)
        rel = parts[1] if len(parts) > 1 else after
        return rel if len(rel) <= limit else rel[: limit - 1] + "\u2026"
    base = os.path.basename(file)
    return base if len(base) <= limit else base[: limit - 1] + "\u2026"


def _is_rules_py(file: str | None) -> bool:
    """True if a pprof source file belongs to the rules_py repo itself."""
    if not file:
        return False
    rel = _relpath(file)
    return rel.startswith("py/") or rel.startswith("uv/")


def _starlark_section(main_result: dict[str, Any], pr_result: dict[str, Any]) -> str:
    """Diagnostic Starlark CPU diff (PR vs main). Informational, not a gate.

    Movers are computed PER FUNCTION and rendered if individually significant
    (delta > FN_SIGMA * combined stderr, with stderr==0 && delta>0 counting as
    significant). They are NOT gated on the signed run-level total: a real
    per-function regression must still surface when an unrelated speedup cancels
    it at the total level (which is exactly what this section exists to explain).
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

    main_n = max(main_total.get("runs", 1) or 1, 1)
    pr_n = max(pr_total.get("runs", 1) or 1, 1)

    main_total_ms = main_total.get("mean_ms", 0.0)
    pr_total_ms = pr_total.get("mean_ms", 0.0)
    delta_total = pr_total_ms - main_total_ms
    pct_total = pct(main_total_ms, pr_total_ms) if main_total_ms else 0.0
    total_se = _combined_se(main_total.get("stddev_ms", 0.0), main_n,
                            pr_total.get("stddev_ms", 0.0), pr_n)

    movers = []
    for name, pr_r in pr_fns.items():
        m_r = main_fns.get(name)
        m_ms = m_r["mean_ms"] if m_r else 0.0
        delta = pr_r["mean_ms"] - m_ms
        if delta <= 0:
            continue
        se = _combined_se(m_r.get("stddev_ms", 0.0) if m_r else 0.0, main_n,
                          pr_r.get("stddev_ms", 0.0), pr_n)
        if not _is_significant(delta, se):
            continue
        movers.append((name, m_ms, pr_r["mean_ms"], delta, se))
    movers.sort(key=lambda x: x[3], reverse=True)

    out = "\n### \U0001f50d Starlark CPU \u2014 where the problem is (PR vs main)\n\n"

    # Honest context: how much of the build's Starlark time is actually rules_py.
    # This sets expectations -- rules_py is usually a minority (the rest is Bazel
    # builtins like alias/config_setting that rules_py merely invokes, plus other
    # deps). Measured levers (alias count, selects, decode) are all small.
    pr_all_ms = sum(r["mean_ms"] for r in pr_fns.values())
    rules_py_ms = sum(r["mean_ms"] for r in pr_fns.values() if _is_rules_py(r.get("file")))
    builtins_ms = sum(r["mean_ms"] for r in pr_fns.values() if _relpath(r.get("file")) == "builtin")
    rp_pct = (rules_py_ms / pr_all_ms * 100.0) if pr_all_ms else 0.0
    out += (
        f"**Total:** main {main_total_ms:.0f} ms, PR {pr_total_ms:.0f} ms "
        f"(\u0394 {delta_total:+.0f} ms). Of PR's Starlark, **rules_py = {rules_py_ms:.0f} ms "
        f"({rp_pct:.0f}%)**, Bazel builtins = {builtins_ms:.0f} ms, rest = other deps.\n\n"
    )

    if movers:
        out += "**Significant movers (\u0394 > 3\u03c3):**\n\n"
        out += "| Function | File | main ms | PR ms | \u0394 ms | \u00b1 stderr | \u0394 % |\n|---|---|---|---|---|---|---|\n"
        for name, m_ms, pr_ms, d, se in movers[:10]:
            dpct = f"+{d / m_ms * 100:.0f}%" if m_ms > 0 else "new"
            out += (
                f"| `{_short(name)}` | `{_relpath(pr_fns[name].get('file'))}` | {m_ms:.1f} | "
                f"{pr_ms:.1f} | +{d:.1f} | \u00b1{se:.1f} | {dpct} |\n"
            )
    else:
        out += "\u2705 **No significant per-function regressions** (all deltas within noise).\n"

    # Hotspots: ONLY rules_py's own functions (builtins like alias/config_setting
    # are NOT actionable -- measured: reducing them does not help). This shows
    # where rules_py's own time goes, which IS actionable.
    hot = [r for r in pr_fns.values() if _is_rules_py(r.get("file"))]
    hot = [r for r in hot if r.get("pct", 0.0) >= HOTSPOT_MIN_PCT][:8]
    if hot:
        out += "\n**rules_py's own top functions (where its time goes):**\n\n"
        out += "| Function | File | PR ms | % of total |\n|---|---|---|---|\n"
        for r in hot:
            out += (
                f"| `{_short(r['name'])}` | `{_relpath(r.get('file'))}` | "
                f"{r['mean_ms']:.1f} | {r.get('pct', 0.0):.1f}% |\n"
            )

    return out


def _phase_table(main_result: dict[str, Any], pr_result: dict[str, Any]) -> str:
    """Inclusive wall time per profile phase, main vs PR (step summary).

    Phase durations are inclusive (spans nest, e.g. runAnalysisPhase is inside
    buildTargets), so they are NOT additive. Surfaces the bzlmod/uv
    module-extension eval separately from analysis -- that is where hub/project
    target generation costs and which runAnalysisPhase cannot see.
    """
    main_ph = {p["name"]: p for p in main_result.get("profile_phases", [])}
    pr_ph = {p["name"]: p for p in pr_result.get("profile_phases", [])}
    if not main_ph and not pr_ph:
        return ""
    names = sorted(set(main_ph) | set(pr_ph),
                   key=lambda n: -(pr_ph.get(n, main_ph.get(n, {})).get("mean_ms", 0.0)))

    out = "## Bazel profile phases (inclusive, non-additive)\n\n"
    out += "_Where wall time goes by phase; module-extension eval is separate from analysis._\n\n"
    out += "| Phase | main ms | PR ms | \u0394 ms |\n|---|---|---|---|\n"
    for name in names[:25]:
        m = main_ph.get(name, {}).get("mean_ms", 0.0)
        p = pr_ph.get(name, {}).get("mean_ms", 0.0)
        out += f"| `{_short(name, 60)}` | {m:.0f} | {p:.0f} | {p - m:+.0f} |\n"
    return out


def run_analysis(args: argparse.Namespace) -> int:
    bcr_path, main_path, pr_path = args.bcr, args.main, args.pr

    mo = getattr(args, "partial", False)
    bcr = load_result(bcr_path, missing_ok=mo)
    main = load_result(main_path, missing_ok=mo)
    pr = load_result(pr_path, missing_ok=mo)

    bcr_aux = load_auxiliary(bcr_path.replace(".json", "-aux.json"))
    main_aux = load_auxiliary(main_path.replace(".json", "-aux.json"))
    pr_aux = load_auxiliary(pr_path.replace(".json", "-aux.json"))

    _incomplete = bcr.get("_pending") or main.get("_pending") or pr.get("_pending")

    def _mean(d):
        return d["analysis_ms"]["mean"] if not d.get("_pending") else 0.0

    main_vs_bcr = pct(_mean(bcr), _mean(main)) if not _incomplete else 0.0
    pr_vs_bcr = pct(_mean(bcr), _mean(pr)) if not _incomplete else 0.0
    pr_vs_main = pct(_mean(main), _mean(pr)) if not _incomplete else 0.0

    has_aux = bcr_aux is not None or main_aux is not None or pr_aux is not None

    table = "## Bazel analysis benchmark\n\n"
    table += "| Version | Analysis (ms) | Median (ms) | \u00b1 stddev | Wall (ms) | vs BCR | vs main | Packages | Targets |\n"
    table += "|---------|--------------|-------------|----------|----------|--------|---------|----------|----------|\n"

    def aux_cell(aux: dict[str, Any] | None) -> str:
        if aux is None:
            return f"{EM} | {EM}"
        return f"{aux.get('packages', EM)} | {aux.get('targets', EM)}"

    def row(label: str, d: dict[str, Any], vs_bcr: str, vs_main: str, aux: dict[str, Any] | None) -> str:
        if d.get("_pending"):
            return f"| {label} | \u23f3 | \u23f3 | \u23f3 | \u23f3 | \u23f3 | \u23f3 | {aux_cell(aux)} |\n"
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

    if args.step_summary:
        phases = _phase_table(main, pr)
        if phases:
            with open(args.step_summary, "a") as f:
                f.write(phases)

    if _incomplete:
        print("\n\u23f3 Partial results \u2014 gate deferred (some variants still running).")
        return 0
    if is_regression(main, pr, THRESHOLD_REGRESSION_PCT):
        print(f"\n\u274c REGRESSION: PR analysis is {pr_vs_main:.1f}% slower than HEAD main "
              f"(threshold: {THRESHOLD_REGRESSION_PCT}%)")
        return 1
    print(f"\n\u2705 No regression detected (PR analysis is {pr_vs_main:+.1f}% vs HEAD main)")
    return 0


# --------------------------------------------------------------------------- #
# startup subcommand
# --------------------------------------------------------------------------- #

def load_runtime(path: str, missing_ok: bool = False) -> dict[str, Any]:
    """Load a single hyperfine runtime JSON result."""
    p = Path(path)
    if not p.exists():
        if missing_ok:
            return {"_pending": True}
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

    mo = getattr(args, "partial", False)
    bcr = load_runtime(bcr_path, missing_ok=mo)
    main = load_runtime(main_path, missing_ok=mo)
    pr = load_runtime(pr_path, missing_ok=mo)

    bcr_syspath = load_syspath(bcr_path.replace(".json", "-syspath.json"))
    main_syspath = load_syspath(main_path.replace(".json", "-syspath.json"))
    pr_syspath = load_syspath(pr_path.replace(".json", "-syspath.json"))

    _inc = bcr.get("_pending") or main.get("_pending") or pr.get("_pending")
    def _ms(d): return d["mean_ms"] if not d.get("_pending") else 0.0
    rt_main_vs_bcr = pct(_ms(bcr), _ms(main)) if not _inc else 0.0
    rt_pr_vs_bcr = pct(_ms(bcr), _ms(pr)) if not _inc else 0.0
    rt_pr_vs_main = pct(_ms(main), _ms(pr)) if not _inc else 0.0

    has_syspath = bcr_syspath is not None or main_syspath is not None or pr_syspath is not None

    table = "## py_binary startup benchmark\n\n"
    table += "| Version | Startup (ms) | Median (ms) | \u00b1 stddev | vs BCR | vs main |\n"
    table += "|---------|-------------|-------------|----------|--------|---------|\n"

    def row(label: str, d: dict[str, Any], vs_bcr: str, vs_main: str) -> str:
        if d.get("_pending"):
            return f"| {label} | \u23f3 | \u23f3 | \u23f3 | \u23f3 | \u23f3 |\n"
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

    if _inc:
        print("\n\u23f3 Partial results \u2014 gate deferred.")
        return 0
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

    analysis_parser = sub.add_parser("analysis", help="analysis_ms gate + Starlark CPU diagnostic")
    add_common(analysis_parser)
    analysis_parser.add_argument(
        "--step-summary",
        default=None,
        help="append the full per-function main-vs-PR table to this file "
        "(e.g. $GITHUB_STEP_SUMMARY for the workflow run summary)",
    )
    for p in (analysis_parser, sub.add_parser("startup", help="runtime gate + sys.path quality")):
        p.add_argument("--partial", action="store_true",
                       help="treat missing result JSONs as pending (show ⏳ instead of failing)")
    args = parser.parse_args()

    rc = run_analysis(args) if args.kind == "analysis" else run_startup(args)
    sys.exit(rc)


if __name__ == "__main__":
    main()
