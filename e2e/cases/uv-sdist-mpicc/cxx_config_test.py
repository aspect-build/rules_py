"""Verify configured C++ wrappers and link flags survive a native sdist build."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import zipfile

_MARKER = "__ASPECT_RULES_PY_EXECROOT__"

_SETUP_PY = """\
import os
import shlex
import subprocess

from setuptools import Extension, setup

with open("sanity.cpp", "w") as f:
    f.write('''
        #include <string>
        #ifndef RULES_PY_FEATURE_CONFIG
        #error compile flags were not applied to one-step C++ probe
        #endif
        extern "C" const char *dependency();
        int main() { return std::string(dependency()) != "rules_py"; }
    ''')
with open("dependency.c", "w") as f:
    f.write('const char *dependency() { return "rules_py"; }')
with open("shared.cpp", "w") as f:
    f.write('int shared_probe() { return 0; }')
cc = shlex.split(os.environ["CC"])
cxx = shlex.split(os.environ["CXX"])
for mode in ("-M", "-MM", "-fsyntax-only"):
    subprocess.run([*cxx, mode, "sanity.cpp"], check=True)
subprocess.run([*cc, "-fPIC", "-c", "dependency.c", "-o", "dependency.o"], check=True)
subprocess.run([*cc, "-dynamiclib" if os.uname().sysname == "Darwin" else "-shared", "dependency.o", "-o", "libdependency.so"], check=True)
link_args = [os.path.abspath("libdependency.so"), "-Wl,-rpath," + os.getcwd(), "-o", "sanity"]
one_step = subprocess.run([*cxx, "sanity.cpp", *link_args], capture_output=True, text=True)
if os.environ.get("RULES_PY_EXPECT_SPLIT"):
    assert one_step.returncode, one_step.stdout
    assert "one-step CXX compile+link cannot use distinct configured compile and link tools" in one_step.stderr, one_step.stderr
    subprocess.run([*cxx, "-c", "sanity.cpp", "-o", "sanity.o"], check=True)
    subprocess.run([*cxx, "sanity.o", *link_args], check=True)
else:
    assert not one_step.returncode, one_step.stderr
subprocess.run(["./sanity"], check=True)
subprocess.run([*cxx, "-fPIC", "-c", "shared.cpp", "-o", "sanity.o"], check=True)
with open("shared.rsp", "w") as f:
    f.write("{} sanity.o".format("-bundle" if os.uname().sysname == "Darwin" else "-shared"))
subprocess.run([*cxx, "@shared.rsp", "-o", "sanity.so"], check=True)

setup(
    name="cxxprobe",
    version="1.0",
    ext_modules=[Extension("cxxprobe", ["cxxprobe.cpp"], language="c++")],
)
"""

_SOURCE = """\
#include <Python.h>
#include <string>

#ifndef RULES_PY_WRAPPER_CONFIG
#define RULES_PY_WRAPPER_CONFIG 0
#endif
#ifndef RULES_PY_FEATURE_CONFIG
#define RULES_PY_FEATURE_CONFIG 0
#endif

#if RULES_PY_WRAPPER_CONFIG != RULES_PY_EXPECT_WRAPPER || !RULES_PY_FEATURE_CONFIG
#error toolchain configuration was not preserved
#endif

struct Base { virtual ~Base() {} };
struct Value : Base {
    std::string value;
    Value() : value("rules_py_cxx_runtime") {}
};

static PyObject *probe(PyObject *, PyObject *) {
    Value value;
    Base *base = &value;
    Value *result = dynamic_cast<Value *>(base);
    return result ? PyUnicode_FromString(result->value.c_str()) : nullptr;
}

static PyMethodDef methods[] = {
    {"probe", probe, METH_NOARGS, nullptr},
    {nullptr, nullptr, 0, nullptr},
};
static PyModuleDef module = {PyModuleDef_HEAD_INIT, "cxxprobe", nullptr, -1, methods};
PyMODINIT_FUNC PyInit_cxxprobe() { return PyModule_Create(&module); }
"""


def _find_build_helper():
    for root, _, files in os.walk(os.environ["TEST_SRCDIR"], followlinks=True):
        if "build_helper.py" in files and root.endswith(os.path.join("uv", "private", "pep517_whl")):
            return os.path.join(root, "build_helper.py")
    raise AssertionError("build_helper.py not found under TEST_SRCDIR")


def _make_sdist(workdir):
    pkgdir = os.path.join(workdir, "cxxprobe-1.0")
    os.makedirs(pkgdir)
    with open(os.path.join(pkgdir, "setup.py"), "w") as f:
        f.write(_SETUP_PY)
    with open(os.path.join(pkgdir, "cxxprobe.cpp"), "w") as f:
        f.write(_SOURCE)
    sdist = os.path.join(workdir, "cxxprobe-1.0.tar.gz")
    with tarfile.open(sdist, "w:gz") as archive:
        archive.add(pkgdir, arcname="cxxprobe-1.0")
    return sdist


def _run(helper, sdist, workdir, compiler, mode):
    use_wrapper = mode == "wrapper"
    split_tools = mode in ("wrapper", "bare")
    run_dir = os.path.join(workdir, mode)
    os.makedirs(run_dir)
    os.makedirs(os.path.join(run_dir, "external"))
    sysroot = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip() if sys.platform == "darwin" else "/"
    os.symlink(sysroot, os.path.join(run_dir, "external", "test_sysroot"))

    wrapper = os.path.join(run_dir, "cc_wrapper.sh")
    with open(wrapper, "w") as f:
        f.write(textwrap.dedent(
            """\
            #!/bin/sh
            for arg in "$@"; do
                case "$arg" in -c|-E|-S|-M|-MM|-fsyntax-only) exec "{}" -DRULES_PY_WRAPPER_CONFIG=1 "$@";; esac
            done
            echo "compile wrapper must not perform C++ links" >&2
            exit 98
            """.format(compiler)
        ))
    os.chmod(wrapper, 0o755)

    shared_wrapper = os.path.join(run_dir, "shared_wrapper.sh")
    exe_wrapper = os.path.join(run_dir, "exe_wrapper.sh")
    with open(shared_wrapper, "w") as f:
        f.write('#!/bin/sh\noutput=0\nfor arg in "$@"; do case "$arg" in -shared|-dynamiclib|-bundle) exec "{}" "$@";; esac; if [ "$output" = 1 ]; then case "$arg" in *.so|*.dylib|*.pyd) exec "{}" "$@";; esac; fi; [ "$arg" = -o ] && output=1 || output=0; done\necho "shared wrapper received a non-shared link" >&2\nexit 96\n'.format(compiler, compiler))
    with open(exe_wrapper, "w") as f:
        f.write('#!/bin/sh\nfor arg in "$@"; do case "$arg" in -shared|-dynamiclib|-bundle) echo "executable wrapper received a shared link" >&2; exit 95;; esac; done\nexec "{}" "$@"\n'.format(compiler))
    os.chmod(shared_wrapper, 0o755)
    os.chmod(exe_wrapper, 0o755)

    compile_flags = [
        "-DRULES_PY_FEATURE_CONFIG=1",
        "-DRULES_PY_EXPECT_WRAPPER={}".format(int(use_wrapper)),
        "--sysroot={}/external/test_sysroot".format(_MARKER),
    ]
    link_flags = ["-bundle", "-lc++"] if sys.platform == "darwin" else ["-shared", "-Wl,--as-needed", "-Bdynamic", "-lstdc++"]
    exe_link_flags = ["--driver-mode=g++"] if "clang" in os.path.basename(compiler) or sys.platform == "darwin" else ["-lstdc++"]
    toolchain_config = {"cc_compile_flags": []}
    if mode != "explicit":
        toolchain_config.update({
            "cxx_compile_flags": compile_flags,
            "cxx_shared_link_flags": link_flags,
            "cxx_exe_link_flags": exe_link_flags,
            "cxx_shared_link_tool": shared_wrapper if use_wrapper else "shared_wrapper.sh" if split_tools else compiler,
            "cxx_exe_link_tool": exe_wrapper if use_wrapper else "exe_wrapper.sh" if split_tools else compiler,
        })
    explicit_cxx = shutil.which("c++") or compiler
    env = {
        "ASPECT_RULES_PY_CXX_TOOLCHAIN_CONFIG": json.dumps(toolchain_config),
        "CC": compiler,
        "CXX": wrapper if use_wrapper else explicit_cxx + " -DRULES_PY_FEATURE_CONFIG=1 -DRULES_PY_EXPECT_WRAPPER=0" if mode == "explicit" else compiler,
        "HOME": workdir,
        "PATH": os.pathsep.join([run_dir, os.environ.get("PATH", "/usr/bin:/bin")]),
    }
    if split_tools:
        env["RULES_PY_EXPECT_SPLIT"] = "1"
    outdir = os.path.join(run_dir, "out")
    result = subprocess.run(
        [sys.executable, helper, "--execroot-marker", _MARKER, sdist, outdir],
        capture_output=True,
        cwd=run_dir,
        env=env,
        text=True,
    )
    if result.returncode:
        raise AssertionError("build_helper failed:\n{}\n{}".format(result.stdout, result.stderr))

    wheel = next(name for name in os.listdir(outdir) if name.endswith(".whl"))
    with zipfile.ZipFile(os.path.join(outdir, wheel)) as archive:
        extension = next(name for name in archive.namelist() if name.startswith("cxxprobe.") and name.endswith((".so", ".pyd")))
        archive.extract(extension, run_dir)
    extension = os.path.join(run_dir, extension)
    if sys.platform == "darwin":
        linked_libraries = subprocess.check_output(["otool", "-L", extension], text=True)
        expected_runtime = "libc++.1.dylib"
    else:
        linked_libraries = subprocess.check_output(["readelf", "--dynamic", extension], text=True)
        expected_runtime = "libstdc++.so"
    assert expected_runtime in linked_libraries, linked_libraries
    spec = importlib.util.spec_from_file_location("cxxprobe", extension)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.probe() == "rules_py_cxx_runtime"


def main():
    workdir = tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"])
    compiler = shutil.which("cc") or "/usr/bin/cc"
    sdist = _make_sdist(workdir)
    helper = _find_build_helper()
    for mode in ("wrapper", "bare", "same", "explicit"):
        _run(helper, sdist, workdir, compiler, mode)


if __name__ == "__main__":
    main()
