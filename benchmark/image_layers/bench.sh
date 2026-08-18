#!/usr/bin/env bash
# Run the py_image_layer benchmark for one variant.
#
# Usage: bench.sh <variant> <generate_module.py args...>
#   e.g. bench.sh bcr bcr --version 2.0.0-alpha.6
#        bench.sh main local --path /path/to/rules_py
#
# Writes hyperfine results to $GITHUB_WORKSPACE (or /tmp when unset) as
# <variant>-full.json, <variant>-inc-source.json, <variant>-inc-wheel.json.
set -euo pipefail

variant="$1"
shift

cd "$(dirname "$0")/../analysis"
results_dir="${GITHUB_WORKSPACE:-/tmp}"

# Smaller workload than the analysis benchmark: build perf, not analysis stress.
# The small dep pool keeps wheel-install and mtree time low; click is forced into
# every image binary's closure as the wheel-change mutation target.
packages=15
python3 workspace/generate_workspace.py --root workspace \
  --packages "$packages" \
  --image-binaries 5 \
  --external-deps click,requests,jinja2,pyyaml \
  --image-common-dep click
last_pkg="pkg_$((packages - 1))"
python3 ../image_layers/write_patch.py --tick 0 workspace/patches/wheel_bench_note.patch
python3 generate_module.py "$@"

out_base="/tmp/bazel-build-$variant"
rm -rf "$out_base"
BAZEL="bazel --output_base=$out_base --bazelrc=../../.github/workflows/ci.bazelrc"

$BAZEL fetch //workspace:image_layers

# Warm-server analysis: a fresh --action_env value discards the analysis cache
# each run while keeping the server and loading warm. The warmup run absorbs
# the cold start.
hyperfine --warmup 1 --runs 10 \
  --export-json "$results_dir/$variant-analysis.json" \
  "$BAZEL build --disk_cache= --nobuild --action_env=BENCH_TICK=\$(date +%s%N) //workspace:image_layers"

# Unmeasured full build to establish the built state for the incremental runs.
$BAZEL build --disk_cache= //workspace:image_layers

hyperfine --warmup 1 --runs 10 \
  --prepare "echo '# tick' >> workspace/src/$last_pkg/lib.py" \
  --export-json "$results_dir/$variant-inc-source.json" \
  "$BAZEL build --disk_cache= //workspace:image_layers"

# One instrumented run per incremental scenario: same mutation, BEP enabled,
# recording how many actions re-execute. Deterministic, unlike wall time.
echo '# tick' >> "workspace/src/$last_pkg/lib.py"
$BAZEL build --disk_cache= --build_event_json_file=/tmp/bep-inc-source.json //workspace:image_layers
python3 ../image_layers/extract_actions.py /tmp/bep-inc-source.json \
  > "$results_dir/$variant-inc-source-actions.json"

hyperfine --warmup 1 --runs 10 \
  --prepare 'python3 ../image_layers/write_patch.py workspace/patches/wheel_bench_note.patch' \
  --export-json "$results_dir/$variant-inc-wheel.json" \
  "$BAZEL build --disk_cache= //workspace:image_layers"

python3 ../image_layers/write_patch.py workspace/patches/wheel_bench_note.patch
$BAZEL build --disk_cache= --build_event_json_file=/tmp/bep-inc-wheel.json //workspace:image_layers
python3 ../image_layers/extract_actions.py /tmp/bep-inc-wheel.json \
  > "$results_dir/$variant-inc-wheel-actions.json"

$BAZEL shutdown
