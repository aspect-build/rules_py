#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import os
import shlex
import shutil
import sys
from os import listdir, mkdir, path
from subprocess import CalledProcessError, check_call, STDOUT, run
from tempfile import TemporaryFile

# fromfile: pep517_native_whl passes native-input flags via an Args object
# that may spill to a Bazel multiline param file (@path, one arg per line).
PARSER = ArgumentParser(fromfile_prefix_chars="@")
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
PARSER.add_argument("--subdirectory", default="", help="Subdirectory within the archive containing pyproject.toml")
# Native inputs: pep517_native_whl derives these from the CcInfo/DefaultInfo
# providers of uv.override_package(native_inputs) targets. Paths are exec-root
# relative; this helper only absolutizes them and maps each to its flag.
PARSER.add_argument("--native-include", action="append", default=[], dest="native_includes", help="Include directory to compile against (-I) (repeatable)")
PARSER.add_argument("--native-quote-include", action="append", default=[], dest="native_quote_includes", help="Quote include directory to compile against (-iquote) (repeatable)")
PARSER.add_argument("--native-system-include", action="append", default=[], dest="native_system_includes", help="System include directory to compile against (-isystem) (repeatable)")
PARSER.add_argument("--native-define", action="append", default=[], dest="native_defines", help="Preprocessor define (-D) (repeatable)")
PARSER.add_argument("--native-static-lib", action="append", default=[], dest="native_static_libs", help="Static library archive to link into extensions (repeatable)")
PARSER.add_argument("--native-link-object", action="append", default=[], dest="native_link_objects", help="Object file to link into extensions (repeatable)")
PARSER.add_argument("--native-input-file", action="append", default=[], dest="native_input_files", help="Auxiliary input file exposed via $PY_NATIVE_INPUT_PATHS (repeatable)")
opts, args = PARSER.parse_known_args()

tmp_root = opts.outdir.lstrip("/") + ".tmp"
mkdir(tmp_root)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# Annoyingly, unpack_archive creates a subdir in the target. Update t
# accordingly. Not worth the eng effort to prevent creating this dir.
t = path.join(t, listdir(t)[0])

if opts.subdirectory:
    t = path.join(t, opts.subdirectory)

if opts.patches:
    for patch_file in opts.patches:
        check_call(
            ["patch", "-p{}".format(opts.patch_strip), "-i", path.abspath(patch_file)],
            cwd=t,
        )


from uv.private.pep517_whl.build_backend import ensure_build_backend
ensure_build_backend(t)

# Get a path to the outdir which will be valid after we cd
outdir = path.abspath(opts.outdir)

# Resolve compiler variables to absolute paths so they remain valid after cwd
# changes into the extracted source tree (Bazel sets these as
# exec-root-relative).
for _cc_var in ("CC", "CXX", "SYSROOT"):
    if _cc_var in os.environ and not path.isabs(os.environ[_cc_var]):
        os.environ[_cc_var] = path.abspath(os.environ[_cc_var])

# Preserve PATH so native sdist builds can find compilers (clang, gcc).
build_env = dict(os.environ)
build_env.update({
    "TMP": tmp_root,
    "TEMP": tmp_root,
    "TEMPDIR": tmp_root,
})


def _append_env_flags(env, key, flags):
    if not flags:
        return
    # distutils/setuptools re-tokenize these env vars with shlex.split, so
    # quote each flag to survive whitespace in defines and paths.
    joined = " ".join(shlex.quote(flag) for flag in flags)
    env[key] = f"{env[key]} {joined}" if env.get(key) else joined


if "SYSROOT" in build_env:
    _sysroot_flag = "--sysroot=" + build_env["SYSROOT"]
    for _flags_var in ("CPPFLAGS", "CFLAGS", "CXXFLAGS"):
        _append_env_flags(build_env, _flags_var, [_sysroot_flag])


_native_compile_flags = (
    ["-I" + path.abspath(d) for d in opts.native_includes]
    + ["-iquote" + path.abspath(d) for d in opts.native_quote_includes]
    + ["-isystem" + path.abspath(d) for d in opts.native_system_includes]
    + ["-D" + d for d in opts.native_defines]
)
# setuptools/distutils customize_compiler() folds CPPFLAGS into both C and C++
# compile commands, but older vendored copies only honor CFLAGS/CXXFLAGS, so
# set all three.
_append_env_flags(build_env, "CPPFLAGS", _native_compile_flags)
_append_env_flags(build_env, "CFLAGS", _native_compile_flags)
_append_env_flags(build_env, "CXXFLAGS", _native_compile_flags)

# distutils splices $LDFLAGS into $LDSHARED, BEFORE the object files on the
# link line. With position-dependent archive scanning (GNU ld/lld) a plain
# libfoo.a there would contribute no symbols and the extension would fail at
# import time with unresolved symbols. Force-loading the whole archive makes
# placement irrelevant; injected build-time libraries are expected to be small.
if sys.platform == "darwin":
    _native_link_flags = [
        "-Wl,-force_load,{}".format(path.abspath(lib)) for lib in opts.native_static_libs
    ]
else:
    _native_link_flags = [
        flag
        for lib in opts.native_static_libs
        for flag in ("-Wl,--whole-archive", path.abspath(lib), "-Wl,--no-whole-archive")
    ]
# Bare object files always contribute their symbols regardless of position.
_native_link_flags += [path.abspath(obj) for obj in opts.native_link_objects]
_append_env_flags(build_env, "LDFLAGS", _native_link_flags)

if opts.native_input_files:
    build_env["PY_NATIVE_INPUT_PATHS"] = os.pathsep.join(
        path.abspath(f) for f in opts.native_input_files
    )

if path.exists(path.join(t, "pyproject.toml")) or path.exists(path.join(t, "setup.py")):
    # Always use `python -m build` (PEP 517 frontend). For setup.py-only
    # packages without a pyproject.toml, build creates a minimal PEP 517
    # shim automatically. --no-isolation ensures it uses the deps we've
    # already provided in the build venv rather than trying to pip-install.
    cmd = [
        sys.executable,
        "-m", "build",
        "--wheel",
        "--no-isolation",
        "--outdir", outdir,
    ]

else:
    print("Error: Unable to detect build command! Neither pyproject.toml nor setup.py found!", file=sys.stderr)
    exit(1)

with TemporaryFile(mode="w+") as build_log:
    try:
        run(cmd, cwd=t, env=build_env, stdout=build_log, stderr=STDOUT, check=True)
    except CalledProcessError:
        build_log.seek(0)
        output = build_log.read()
        if output:
            sys.stderr.write(output)
            if not output.endswith("\n"):
                sys.stderr.write("\n")
        if opts.native_static_libs and "-fPIC" in output:
            # PIC-ness of a prebuilt archive is undetectable at analysis time;
            # this is the earliest point where the mismatch surfaces.
            print(
                "Hint: a native_inputs static library appears to contain non-PIC "
                "objects, which cannot be linked into a Python extension (.so). "
                "Provide a PIC archive (cc_library emits one; cc_import cannot).",
                file=sys.stderr,
            )
        print("Error: Build failed!\nSee {} for the sandbox".format(t), file=sys.stderr)
        exit(1)

inventory = listdir(outdir)

if len(inventory) > 1:
    print("Error: Built more than one wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)

if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
    print("Error: Target was anyarch but built a none-any wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)
