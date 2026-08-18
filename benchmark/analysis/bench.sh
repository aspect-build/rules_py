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

python3 workspace/generate_workspace.py --root workspace --packages 50
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

targets=$($BAZEL query //workspace/... | wc -l | tr -d ' ')
actions=$($BAZEL aquery --output=summary '//workspace/... + //workspace:image_layers' \
  | awk '/^[0-9]+ total actions\.$/ { print $1 }')
test -n "$targets" && test -n "$actions"
echo "{\"targets\": $targets, \"actions\": $actions}" > "$results_dir/$variant-aux.json"

$BAZEL shutdown
