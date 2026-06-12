#!/usr/bin/env bash
# Reproduces https://github.com/aspect-build/rules_py/issues/1095
#
# Asserts that the @python_interpreters hub registers a Python C/C++ headers
# toolchain (@rules_python//python/cc:toolchain_type). Without it, native Python
# extensions (nanobind/pybind11) cannot resolve Python.h through
# @rules_python//python/cc:current_py_cc_headers when only python_interpreters is
# providing toolchains.

set -euo pipefail

hub_build="${TEST_SRCDIR}/_main/cases/py-cc-toolchain-1095/hub_build.txt"

if [[ ! -f "$hub_build" ]]; then
    echo "FAIL: could not find generated hub BUILD at $hub_build"
    exit 1
fi

echo "Toolchain types registered by @python_interpreters//:all:"
grep -o 'toolchain_type = "[^"]*"' "$hub_build" | sort -u | sed 's/^/  /'

if grep -q 'python/cc:toolchain_type' "$hub_build"; then
    echo "PASS: python_interpreters registers a @rules_python//python/cc:toolchain_type (py_cc) toolchain"
    exit 0
fi

echo
echo "FAIL: python_interpreters does NOT register a @rules_python//python/cc:toolchain_type (py_cc) toolchain."
echo "      Native Python extensions resolving @rules_python//python/cc:current_py_cc_headers"
echo "      will fail with: No matching toolchains found for types:"
echo "        @@rules_python+//python/cc:toolchain_type"
echo "      See https://github.com/aspect-build/rules_py/issues/1095"
exit 1
