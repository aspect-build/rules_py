#!/usr/bin/env bash
# Run the startup benchmark for one variant.
#
# Usage: bench.sh <variant> <generate_module.py args...>
#   e.g. bench.sh bcr bcr --version 1.11.7
#        bench.sh main local --path /path/to/rules_py
#
# Writes results to $GITHUB_WORKSPACE (or /tmp when unset) as
# <variant>.json (hyperfine), <variant>-build.json, <variant>-syspath.json.
set -euo pipefail

variant="$1"
shift

cd "$(dirname "$0")"
results_dir="${GITHUB_WORKSPACE:-/tmp}"

python3 generate_module.py "$@"

out_base="/tmp/bazel-$variant"
rm -rf "$out_base"
BAZEL="bazel --output_base=$out_base --bazelrc=../../.github/workflows/ci.bazelrc"

# Untimed prefetch: external repos come from the shared repository cache, so
# build_ms measures build actions rather than network.
$BAZEL fetch //:bench //:bench_syspath

start=$(date +%s%N)
$BAZEL build --disk_cache= //:bench //:bench_syspath
end=$(date +%s%N)
echo "{\"build_ms\": $(( (end - start) / 1000000 ))}" > "$results_dir/$variant-build.json"

bin=$($BAZEL cquery //:bench --disk_cache= --output=starlark --starlark:expr='target.files_to_run.executable.path' | tail -n1)
abs_bin="$out_base/execroot/_main/$bin"
test -x "$abs_bin" || { echo "ERROR: benchmark binary not executable: $abs_bin"; exit 1; }
# --shell=none: exec the binary directly, no shell-spawn jitter in ~100ms samples.
RUNFILES_DIR="$abs_bin.runfiles" hyperfine --warmup 5 --runs 50 --shell=none \
  --export-json "$results_dir/$variant.json" "$abs_bin"

bin_sp=$($BAZEL cquery //:bench_syspath --disk_cache= --output=starlark --starlark:expr='target.files_to_run.executable.path' | tail -n1)
abs_bin_sp="$out_base/execroot/_main/$bin_sp"
test -x "$abs_bin_sp" || { echo "ERROR: bench_syspath binary not executable: $abs_bin_sp"; exit 1; }
RUNFILES_DIR="$abs_bin_sp.runfiles" "$abs_bin_sp" "$results_dir/$variant-syspath.json"

$BAZEL shutdown
