#!/usr/bin/env bash
#
# The PEP 517 native-wheel action uses the named `target` execution group.
# Its frontend must be configured for that group rather than Bazel's default
# execution group when the two select different platforms.
# A build_test cannot scope --extra_execution_platforms to one target:
# https://bazel.build/reference/command-line-reference#flag--extra_execution_platforms
# Registering the synthetic opposite-architecture platform globally would
# make it eligible for unrelated e2e actions, so keep both flags local here.
set -euo pipefail

cd "$(dirname "$0")/../.."  # e2e workspace root

BAZEL="${BAZEL:-bazel}"
PKG="//cases/pep517-frontend-exec-group"

case "$(uname -m)" in
    aarch64 | arm64)
        target_platform="linux_x86_64"
        expected="x86_64"
        ;;
    *)
        target_platform="linux_aarch64"
        expected="aarch64"
        ;;
esac

FLAGS=(
    "--host_platform=@platforms//host"
    "--platforms=${PKG}:${target_platform}"
    "--extra_execution_platforms=@platforms//host,${PKG}:${target_platform}"
)

"${BAZEL}" build "${FLAGS[@]}" "${PKG}:wheel"

wheel_dir="$("${BAZEL}" info "${FLAGS[@]}" bazel-bin)/cases/pep517-frontend-exec-group/whl"
actual="$(cat "${wheel_dir}/frontend_exec_platform.txt")"
if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: frontend used ${actual}; expected target exec group ${expected}" >&2
    exit 1
fi

echo "PASS: frontend used the target execution platform"
