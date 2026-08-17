#!/usr/bin/env bash
set -euo pipefail

expected_cc="$1"
expected_cxx="$2"
compile="$3"
if [[ "${CC-unset}" != ${expected_cc} || "${CXX-unset}" != ${expected_cxx} ]]; then
    echo "C++ tools were not selected: CC=${CC-unset} CXX=${CXX-unset}" >&2
    exit 1
fi
if [[ "${CC-unset}" == "${CXX-unset}" && "${ASPECT_RULES_PY_INFER_CXX_COMPANION-0}" != 1 ]]; then
    echo "same-driver CXX was not marked for companion inference" >&2
    exit 1
fi
if [[ "${CC-unset}" != "${CXX-unset}" && "${ASPECT_RULES_PY_INFER_CXX_COMPANION-0}" != 0 ]]; then
    echo "configured CXX was incorrectly marked for companion inference" >&2
    exit 1
fi

wheel_out="${!#}"
work_dir="${wheel_out}.tmp"
mkdir -p "${work_dir}"
if [[ "${compile}" == 1 ]]; then
    cat >"${work_dir}/probe.cc" <<'EOF'
#include <string>

struct Base { virtual ~Base() {} };
struct Value : Base { std::string value; Value() : value("rules_py") {} };

extern "C" const char *probe() {
    static Value value;
    Base *base = &value;
    Value *result = dynamic_cast<Value *>(base);
    return result ? result->value.c_str() : "dynamic_cast failed";
}

int main() { return std::string(probe()) == "rules_py" ? 0 : 1; }
EOF
    read -r -a cxx <<<"${CXX}"
    "${cxx[@]}" -std=c++11 "${work_dir}/probe.cc" -o "${work_dir}/probe"
    "${work_dir}/probe"
    "${cxx[@]}" -std=c++11 -shared -fPIC "${work_dir}/probe.cc" -o "${work_dir}/probe.so"
    /usr/bin/python3 -c 'import ctypes, sys; probe = ctypes.CDLL(sys.argv[1]).probe; probe.restype = ctypes.c_char_p; assert probe() == b"rules_py"' "${work_dir}/probe.so"
fi
: > "${wheel_out}"
