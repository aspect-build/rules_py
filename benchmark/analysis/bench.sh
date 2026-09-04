#!/usr/bin/env bash
# Run the analysis benchmark for one variant.
#
# Usage: bench.sh <variant> <generate_module.py args...>
#   e.g. bench.sh bcr bcr --version 2.0.0-alpha.6
#        bench.sh main local --path /path/to/rules_py
#
# Writes results to $GITHUB_WORKSPACE (or /tmp when unset) as
# <variant>.json (hyperfine) and <variant>-aux.json (target/action counts).
set -euo pipefail

variant="$1"
shift

cd "$(dirname "$0")"
results_dir="${GITHUB_WORKSPACE:-/tmp}"

# ANALYSIS_DEP_GROUPS (e.g. "default,dev,test") assigns dep_groups to packages
# round-robin, fanning the @pypi hub out into one configuration per group.
python3 workspace/generate_workspace.py --root workspace --packages 50 \
  ${ANALYSIS_DEP_GROUPS:+--dep-groups "$ANALYSIS_DEP_GROUPS"}
python3 generate_module.py "$@"

out_base="/tmp/bazel-$variant"
rm -rf "$out_base"
BAZEL="bazel --output_base=$out_base --bazelrc=../../.github/workflows/ci.bazelrc"

$BAZEL fetch //workspace/... //workspace:image_layers

# Warm-server analysis: a fresh --action_env value discards the analysis cache
# each run while keeping the server and loading warm, so samples measure
# analysis instead of JVM boot + repo extraction. Warmup absorbs cold start.
hyperfine --warmup 1 --runs 10 \
  --export-json "$results_dir/$variant.json" \
  "$BAZEL build --disk_cache= --nobuild --action_env=BENCH_TICK=\$(date +%s%N) //workspace/... //workspace:image_layers"

# Aux metrics: target count, per-mnemonic action counts, and configured-target
# counts split workspace/external. The external CT count exposes config fan-out
# (e.g. per-dep_group duplication of the @pypi alias chains) that the plain
# target count cannot see.
$BAZEL query //workspace/... > "$results_dir/$variant-targets.txt"
$BAZEL aquery --output=summary '//workspace/... + //workspace:image_layers' \
  > "$results_dir/$variant-aquery.txt"
$BAZEL cquery 'deps(//workspace/... + //workspace:image_layers)' \
  > "$results_dir/$variant-cquery.txt"
python3 aux_metrics.py \
  "$results_dir/$variant-targets.txt" \
  "$results_dir/$variant-aquery.txt" \
  "$results_dir/$variant-cquery.txt" \
  > "$results_dir/$variant-aux.json"

$BAZEL shutdown
