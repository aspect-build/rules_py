#!/usr/bin/env python3
"""Run a bazel command N times with --profile and report the analysis-phase
duration extracted from each profile, replacing wall-time benchmark gating.

The relevant metric for Starlark-rule performance is Bazel's analysis phase
(runAnalysisPhase event), not process wall time (~99% JVM/IO overhead unrelated
to rules_py). See tdr.md.

Generic mode -- pass the bazel command with a {PROFILE} placeholder:

    python3 profile_benchmark.py --runs 10 --warmup 1 \\
        --prepare 'rm -rf /tmp/baz-analysis' --output pr.json \\
        -- bazel --output_base=/tmp/baz-analysis --bazelrc=... \\
          build --disk_cache= --nobuild --profile={PROFILE} //...

Analysis convenience mode (--packages) -- clean, generate the synthetic
workspace, generate MODULE.bazel (local checkout) and run the analysis
benchmark in one shot. Coupled to benchmark/workspace by design:

    python3 profile_benchmark.py --packages 50

Output JSON (consumed by compare.py): analysis_ms and wall_ms stats in ms,
plus an optional starlark_fn breakdown (per-function CPU) when the command
also carries {STARPROFILE} for --starlark_cpu_profile.

    python3 profile_benchmark.py --packages 50
    python3 profile_benchmark.py --no-starlark-profile --packages 50  # fast, no fn breakdown
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from pprof_decode import decode_starlark_pprof

PROFILE_PLACEHOLDER = "{PROFILE}"
STAR_PLACEHOLDER = "{STARPROFILE}"
DEFAULT_OUTPUT_BASE = "/tmp/bazel_pbench"


def extract_analysis_us(profile_path: str) -> int | None:
    """Return the runAnalysisPhase duration (microseconds) from a Bazel profile."""
    with gzip.open(profile_path, "rt") as f:
        data = json.load(f)
    for event in data.get("traceEvents", []):
        if event.get("name") == "runAnalysisPhase" and "dur" in event:
            return int(event["dur"])
    return None


def stats_ms(values_ms: list[float]) -> dict[str, float]:
    """Aggregate millisecond durations into statistics (min/mean/median/stddev)."""
    count = len(values_ms)
    return {
        "mean": statistics.mean(values_ms),
        "median": statistics.median(values_ms),
        "stddev": statistics.stdev(values_ms) if count > 1 else 0.0,
        "min": min(values_ms),
        "max": max(values_ms),
        "runs": count,
    }


def aggregate_starlark(star_runs: list[dict[str, tuple[float, str]]]) -> dict[str, Any]:
    """Aggregate per-run {fn: (ms, file)} dicts into per-function stats + total.

    Returns {'total': {mean_ms, stddev_ms, runs}, 'functions': [...]}. ALL
    functions are kept (truncation is render-time in compare.py) and each carries
    its stddev across runs and source file so the comparator can flag only
    statistically significant deltas and point at where to read the code.
    """
    runs = len(star_runs)
    names: set[str] = set()
    for d in star_runs:
        names.update(d.keys())
    functions: list[dict[str, Any]] = []
    for name in names:
        series = [d[name][0] for d in star_runs if name in d]
        file = next((d[name][1] for d in star_runs if name in d and d[name][1]), "<unknown>")
        functions.append({
            "name": name,
            "file": file,
            "mean_ms": statistics.mean(series),
            "stddev_ms": statistics.stdev(series) if len(series) > 1 else 0.0,
        })
    totals = [sum(ms for (ms, _f) in d.values()) for d in star_runs]
    total_mean = statistics.mean(totals)
    total_std = statistics.stdev(totals) if len(totals) > 1 else 0.0
    for r in functions:
        r["pct"] = (r["mean_ms"] / total_mean * 100.0) if total_mean else 0.0
        r["runs"] = runs
    functions.sort(key=lambda r: r["mean_ms"], reverse=True)
    return {
        "total": {"mean_ms": total_mean, "stddev_ms": total_std, "runs": runs},
        "functions": functions,
    }


def substitute(command: list[str], replacements: dict[str, str]) -> list[str]:
    """Inject placeholder paths into the command. {PROFILE} is required."""
    if not any(PROFILE_PLACEHOLDER in tok for tok in command):
        raise SystemExit(
            f"ERROR: command must contain a '{PROFILE_PLACEHOLDER}' token for --profile"
        )
    full = command
    for placeholder, path in replacements.items():
        full = [tok.replace(placeholder, path) for tok in full]
    return full


def _copy_profile(src: str, dst: str) -> None:
    """Copy a captured profile to an archive path, creating parent dirs."""
    if not os.path.exists(src):
        return
    dst_path = Path(dst)
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    print(f"saved profile -> {dst}", file=sys.stderr)


def run_once(
    command: list[str],
    prepare: str | None,
    profile_path: str,
    star_path: str | None,
    cwd: str | None = None,
) -> tuple[int, float, dict[str, float] | None]:
    """Run a single measured invocation. Returns (analysis_us, wall_ms, starlark_fn|None)."""
    if prepare:
        subprocess.run(prepare, shell=True, check=True)
    replacements = {PROFILE_PLACEHOLDER: profile_path}
    if star_path is not None:
        replacements[STAR_PLACEHOLDER] = star_path
    full = substitute(command, replacements)
    start = time.perf_counter()
    result = subprocess.run(full, cwd=cwd)
    wall_ms = (time.perf_counter() - start) * 1000.0
    if result.returncode != 0:
        raise SystemExit(f"ERROR: command failed (exit {result.returncode}): {' '.join(full)}")
    analysis_us = extract_analysis_us(profile_path)
    if analysis_us is None:
        raise SystemExit(f"ERROR: runAnalysisPhase not found in {profile_path}")
    starlark = decode_starlark_pprof(star_path) if star_path is not None else None
    return analysis_us, wall_ms, starlark


def _workspace_dir() -> Path:
    return Path(__file__).resolve().parent / "workspace"


def prepare_workspace(packages: int) -> Path:
    """Clean and regenerate the synthetic workspace + MODULE.bazel.

    Runs the generators with cwd=benchmark/workspace so relative paths in them
    (e.g. generate_module's default --path ../..) resolve against the repo root.
    """
    workspace = _workspace_dir()
    ws_gen = workspace / "generate_workspace.py"
    mod_gen = workspace / "generate_module.py"
    for script in (ws_gen, mod_gen):
        if not script.exists():
            raise SystemExit(f"ERROR: generator not found: {script}")
    print(f"[setup] cleaning + generating {packages} packages in {workspace}", file=sys.stderr)
    subprocess.run(
        [sys.executable, str(ws_gen), "--root", ".", "--packages", str(packages)],
        cwd=str(workspace),
        check=True,
    )
    subprocess.run(
        [sys.executable, str(mod_gen), "local"],
        cwd=str(workspace),
        check=True,
    )
    return workspace


def default_analysis_command() -> list[str]:
    """Construct the analysis bazel command (//..., ci.bazelrc)."""
    repo_root = _workspace_dir().parent.parent
    bazelrc = repo_root / ".github" / "workflows" / "ci.bazelrc"
    return [
        "bazel",
        f"--output_base={DEFAULT_OUTPUT_BASE}",
        f"--bazelrc={bazelrc}",
        "build",
        "--disk_cache=",
        "--nobuild",
        f"--profile={PROFILE_PLACEHOLDER}",
        f"--starlark_cpu_profile={STAR_PLACEHOLDER}",
        "//...",
    ]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a bazel command N times with --profile and report analysis-phase stats.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--runs", type=int, default=10, help="measured runs (default 10)")
    parser.add_argument("--warmup", type=int, default=1, help="warmup runs, discarded (default 1)")
    parser.add_argument("--prepare", default=None, help="shell command run before each invocation")
    parser.add_argument("--output", default=None, help="path to write aggregate JSON (optional)")
    parser.add_argument(
        "--packages",
        type=int,
        default=None,
        help="analysis convenience mode: clean + generate N-package workspace + MODULE.bazel, "
        "then run the analysis benchmark",
    )
    parser.add_argument(
        "--no-starlark-profile",
        action="store_true",
        help="disable --starlark_cpu_profile capture (skip per-function breakdown)",
    )
    parser.add_argument(
        "--save-profile",
        default=None,
        help="copy the last run's --profile (chrome trace .gz) here for archival",
    )
    parser.add_argument(
        "--save-starlark",
        default=None,
        help="copy the last run's --starlark_cpu_profile (pprof .gz) here for archival",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="bazel command; separate from options with '--'. Must contain {PROFILE}. "
        "Omit when using --packages.",
    )
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]

    run_cwd: str | None = None
    if args.packages is not None:
        run_cwd = str(prepare_workspace(args.packages))
        if not command:
            command = default_analysis_command()
            if args.prepare is None:
                args.prepare = f"rm -rf {DEFAULT_OUTPUT_BASE}"
    elif not command:
        parser.error("a bazel command containing {PROFILE} is required (or use --packages)")

    fd, profile_path = tempfile.mkstemp(suffix=".gz", prefix="profile_benchmark_")
    os.close(fd)
    star_enabled = (not args.no_starlark_profile) and any(
        STAR_PLACEHOLDER in tok for tok in command
    )
    fd2, star_path = tempfile.mkstemp(suffix=".gz", prefix="starlark_profile_")
    os.close(fd2)
    try:
        for _ in range(args.warmup):
            run_once(command, args.prepare, profile_path,
                     star_path if star_enabled else None, cwd=run_cwd)
        analysis_us: list[float] = []
        wall_ms: list[float] = []
        star_runs: list[dict[str, float]] = []
        for i in range(args.runs):
            a, w, star = run_once(command, args.prepare, profile_path,
                                  star_path if star_enabled else None, cwd=run_cwd)
            analysis_us.append(a)
            wall_ms.append(w)
            if star:
                star_runs.append(star)
            print(
                f"run {i + 1}/{args.runs}: analysis={a / 1000.0:.1f}ms wall={w:.0f}ms",
                file=sys.stderr,
            )
        if args.save_profile:
            _copy_profile(profile_path, args.save_profile)
        if args.save_starlark and star_enabled:
            _copy_profile(star_path, args.save_starlark)
    finally:
        Path(profile_path).unlink(missing_ok=True)
        Path(star_path).unlink(missing_ok=True)

    output: dict[str, Any] = {
        "analysis_ms": stats_ms([us / 1000.0 for us in analysis_us]),
        "wall_ms": stats_ms(wall_ms),
    }

    if star_runs:
        output["starlark_fn"] = aggregate_starlark(star_runs)

    if args.output:
        Path(args.output).write_text(json.dumps(output, indent=2))

    a = output["analysis_ms"]
    print(
        f"\nanalysis_ms: mean={a['mean']:.1f} median={a['median']:.1f} "
        f"stddev={a['stddev']:.1f} (n={a['runs']})",
        file=sys.stderr,
    )
    if args.output:
        print(f"wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
