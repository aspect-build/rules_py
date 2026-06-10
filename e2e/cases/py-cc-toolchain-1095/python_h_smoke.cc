// Smoke source for https://github.com/aspect-build/rules_py/issues/1095.
//
// Mirrors what a native Python extension (nanobind/pybind11) needs: resolve and
// compile against the active Python toolchain's headers via
// @rules_python//python/cc:current_py_cc_headers. If python_interpreters does
// not register a @rules_python//python/cc:toolchain_type toolchain, analysis of
// this target fails with "No matching toolchains found".
#include <Python.h>

int python_abi_version() {
    return PY_MAJOR_VERSION * 100 + PY_MINOR_VERSION;
}
