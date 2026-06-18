#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

execroot="${TEST_SRCDIR%/bazel-out/*}"

status_script="${execroot}/bazel-out/bazel_env-opt/bin/cases/current-py-toolchain-bazel-env-896/python_env.sh"
if [[ ! -f "${status_script}" ]]; then
    echo "ERROR: status script not found at ${status_script}"
    exit 1
fi
echo "OK: status script exists at ${status_script}"

if grep -q "python" "${status_script}"; then
    echo "OK: status script mentions python toolchain"
else
    echo "ERROR: status script does not mention python toolchain"
    exit 1
fi

toolchain_symlink="${execroot}/bazel-out/bazel_env-opt/bin/cases/current-py-toolchain-bazel-env-896/python_env/toolchains/python"
if [[ ! -L "${toolchain_symlink}" ]]; then
    echo "ERROR: toolchain symlink not found at ${toolchain_symlink}"
    exit 1
fi
echo "OK: toolchain symlink exists at ${toolchain_symlink}"

toolchain_python="${toolchain_symlink}/bin/python3"
if [[ ! -f "${toolchain_python}" ]]; then
    echo "ERROR: interpreter not found at ${toolchain_python}"
    exit 1
fi
echo "OK: interpreter exists at ${toolchain_python}"

if "${toolchain_python}" -c 'import sys; print(sys.version)'; then
    echo "OK: interpreter executed successfully"
else
    echo "ERROR: interpreter failed to execute"
    exit 1
fi

echo "PASS"
exit 0
