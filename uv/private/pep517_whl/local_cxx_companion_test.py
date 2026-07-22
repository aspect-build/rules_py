"""Verify local C-driver companions without guessing relative or missing tools."""

import os
import subprocess
import sys
import tarfile
import tempfile
import textwrap

_SETUP_PY = """\
import ctypes
import os
import shlex
import subprocess

from setuptools import setup

cxx = shlex.split(os.environ["CXX"])
expect = os.environ["CXX_TEST_EXPECT"]
if expect == "runtime":
    with open("probe.cpp", "w") as f:
        f.write('''
            #include <string>
            #ifndef RULES_PY_CXX_ARG_PRESERVED
            #error CXX arguments were not preserved
            #endif
            struct Base { virtual ~Base() {} };
            struct Value : Base { std::string value; Value() : value("rules_py") {} };
            extern "C" const char *probe() {
                static Value value;
                Base *base = &value;
                Value *result = dynamic_cast<Value *>(base);
                return result ? result->value.c_str() : "dynamic_cast failed";
            }
        ''')
    subprocess.run([*cxx, "-std=c++11", "-shared", "-fPIC", "probe.cpp", "-o", "probe.so"], check=True)
    probe = ctypes.CDLL(os.path.abspath("probe.so")).probe
    probe.restype = ctypes.c_char_p
    assert probe() == b"rules_py"
else:
    result = subprocess.run([*cxx, "--version"], capture_output=True, text=True, check=True)
    assert expect in result.stdout, result.stdout

setup(name="cxxprobe", version="1.0", py_modules=[])
"""


def _make_sdist(workdir: str) -> str:
    pkgdir = os.path.join(workdir, "cxxprobe-1.0")
    os.makedirs(pkgdir)
    with open(os.path.join(pkgdir, "setup.py"), "w") as f:
        f.write(_SETUP_PY)
    sdist = os.path.join(workdir, "cxxprobe-1.0.tar.gz")
    with tarfile.open(sdist, "w:gz") as archive:
        archive.add(pkgdir, arcname="cxxprobe-1.0")
    return sdist


def _write_driver(filename: str, message: str) -> None:
    with open(filename, "w") as f:
        f.write(textwrap.dedent("""\
            #!/bin/sh
            for arg in "$@"; do if [ "$arg" = "--version" ]; then echo "{}"; exit 0; fi; done
            echo "unexpected fake-driver invocation" >&2
            exit 1
        """).format(message))
    os.chmod(filename, 0o755)


def _run(helper: str, sdist: str, workdir: str, cxx: str, expect: str, infer_companion: bool) -> None:
    outdir = os.path.join(workdir, "out-" + expect)
    result = subprocess.run(
        [sys.executable, helper, sdist, outdir],
        capture_output=True,
        cwd=workdir,
        env={
            "CC": cxx,
            "CXX": cxx,
            "CXX_TEST_EXPECT": expect,
            "HOME": workdir,
            "PATH": "/usr/bin:/bin",
            "ASPECT_RULES_PY_INFER_CXX_COMPANION": "1" if infer_companion else "0",
        },
        text=True,
    )
    if result.returncode:
        raise AssertionError("build_helper failed for {}:\n{}\n{}".format(expect, result.stdout, result.stderr))


def main() -> None:
    workdir = tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"])
    sdist = _make_sdist(workdir)
    helper = os.path.join(os.path.dirname(__file__), "build_helper.py")
    _run(helper, sdist, workdir, "/usr/bin/gcc -DRULES_PY_CXX_ARG_PRESERVED=1", "runtime", True)

    missing = os.path.join(workdir, "missing")
    os.makedirs(missing)
    _write_driver(os.path.join(missing, "gcc"), "MISSING-PEER-C-DRIVER")
    _run(helper, sdist, workdir, os.path.join(missing, "gcc"), "MISSING-PEER-C-DRIVER", True)

    mingw = os.path.join(workdir, "mingw")
    os.makedirs(mingw)
    _write_driver(os.path.join(mingw, "x86_64-w64-mingw32-gcc-13.exe"), "MINGW-C-DRIVER")
    _write_driver(os.path.join(mingw, "x86_64-w64-mingw32-g++-13.exe"), "MINGW-CXX-DRIVER")
    _run(helper, sdist, workdir, os.path.join(mingw, "x86_64-w64-mingw32-gcc-13.exe"), "MINGW-CXX-DRIVER", True)
    _write_driver(os.path.join(mingw, "aarch64-w64-mingw32-clang.exe"), "MINGW-CLANG-C-DRIVER")
    _write_driver(os.path.join(mingw, "aarch64-w64-mingw32-clang++.exe"), "MINGW-CLANG-CXX-DRIVER")
    _run(helper, sdist, workdir, os.path.join(mingw, "aarch64-w64-mingw32-clang.exe"), "MINGW-CLANG-CXX-DRIVER", True)

    relative = os.path.join(workdir, "relative")
    os.makedirs(relative)
    _write_driver(os.path.join(relative, "gcc"), "RELATIVE-C-DRIVER")
    _write_driver(os.path.join(relative, "g++"), "POISON-RELATIVE-CXX-PEER")
    _run(helper, sdist, workdir, "relative/gcc", "RELATIVE-C-DRIVER", True)

    explicit = os.path.join(workdir, "explicit")
    os.makedirs(explicit)
    _write_driver(os.path.join(explicit, "gcc"), "EXPLICIT-CXX-WRAPPER")
    _write_driver(os.path.join(explicit, "g++"), "POISON-EXPLICIT-CXX-PEER")
    _run(helper, sdist, workdir, os.path.join(explicit, "gcc"), "EXPLICIT-CXX-WRAPPER", False)


if __name__ == "__main__":
    main()
