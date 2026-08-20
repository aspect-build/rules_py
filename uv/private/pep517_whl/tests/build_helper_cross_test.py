"""Verify build_helper.py's cross-build runtime-identity faking end to end.

A package's setup.py can branch on platform.machine()/os.uname() directly
(e.g. to pick a vectorized code path) — sysconfig.get_platform() env vars
don't reach that. This drives build_helper.py exactly as sdist_build's
generated build_tool does (a plain subprocess against a real sdist), so it
also exercises exactly what pycross-distutils-probe/uv-sdist-mpicc rely on:
build_helper.py must stay importable as a bare script with no sibling-module
dependencies, since those tests find it by path and run it standalone.
"""

import os
import subprocess
import sys
import tarfile
import tempfile

_SETUP_PY = """\
import os
import platform
import sys

from setuptools import setup

expected = os.environ.get("EXPECTED_MACHINE")
if expected is not None:
    if platform.machine() != expected:
        sys.exit("WRONG_PLATFORM_MACHINE: saw {!r}, expected {!r}".format(platform.machine(), expected))
    if os.uname().machine != expected:
        sys.exit("WRONG_UNAME_MACHINE: saw {!r}, expected {!r}".format(os.uname().machine, expected))
    if os.environ.get("EXPECT_MANYLINUX_DISABLED") == "1":
        import _manylinux
        if _manylinux.manylinux_compatible(2, 17, expected):
            sys.exit("MANYLINUX_NOT_DISABLED")

expected_ar = os.environ.get("EXPECTED_AR_BASENAME")
if expected_ar is not None:
    seen_ar = os.path.basename(os.environ.get("AR", ""))
    if seen_ar != expected_ar:
        sys.exit("WRONG_AR: saw {!r}, expected {!r}".format(seen_ar, expected_ar))

setup(name="cross_site_probe", version="1.0", py_modules=[])
"""


def _make_fake_llvm_bindir(workdir: str) -> str:
    bindir = os.path.join(workdir, "llvm-bin")
    os.makedirs(bindir)
    for tool in ("llvm-libtool-darwin", "llvm-ar"):
        with open(os.path.join(bindir, tool), "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(os.path.join(bindir, tool), 0o755)
    return bindir


def _make_sdist(workdir: str) -> str:
    pkgdir = os.path.join(workdir, "cross_site_probe-1.0")
    os.makedirs(pkgdir)
    with open(os.path.join(pkgdir, "setup.py"), "w") as f:
        f.write(_SETUP_PY)
    sdist = os.path.join(workdir, "cross_site_probe-1.0.tar.gz")
    with tarfile.open(sdist, "w:gz") as archive:
        archive.add(pkgdir, arcname="cross_site_probe-1.0")
    return sdist


def _run(helper: str, sdist: str, workdir: str, label: str, env: dict, args: list) -> None:
    outdir = os.path.join(workdir, "out-" + label)
    full_env = {"HOME": workdir, "PATH": "/usr/bin:/bin"}
    full_env.update(env)
    result = subprocess.run(
        [sys.executable, helper, *args, sdist, outdir],
        capture_output=True,
        cwd=workdir,
        env=full_env,
        text=True,
    )
    if result.returncode:
        raise AssertionError("build_helper failed for {}:\n{}\n{}".format(label, result.stdout, result.stderr))


def main() -> None:
    workdir = tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"])
    sdist = _make_sdist(workdir)
    helper = os.path.join(os.path.dirname(os.path.dirname(__file__)), "tools", "build_helper.py")

    real_machine = os.uname().machine
    fake_machine = "aarch64" if real_machine != "aarch64" else "x86_64"

    # Cross build: setup.py must see the FAKED target arch, not the host's,
    # and manylinux compatibility must be refused for it.
    _run(
        helper,
        sdist,
        workdir,
        "cross",
        {"EXPECTED_MACHINE": fake_machine, "EXPECT_MANYLINUX_DISABLED": "1"},
        ["--cross", "--target-os", "linux", "--target-cpu", fake_machine],
    )

    # Native build: no faking involved — setup.py must see the real host arch.
    _run(helper, sdist, workdir, "native", {"EXPECTED_MACHINE": real_machine}, [])

    # llvm-libtool-darwin (the llvm toolchain's static-library tool on darwin
    # exec hosts) only takes libtool-style args, but every $AR consumer
    # invokes ar-style — the helper must swap in the sibling llvm-ar for
    # native and cross builds alike.
    fake_ar = os.path.join(_make_fake_llvm_bindir(workdir), "llvm-libtool-darwin")
    _run(
        helper,
        sdist,
        workdir,
        "ar-swap-native",
        {"AR": fake_ar, "EXPECTED_AR_BASENAME": "llvm-ar"},
        [],
    )
    _run(
        helper,
        sdist,
        workdir,
        "ar-swap-cross",
        {"AR": fake_ar, "EXPECTED_AR_BASENAME": "llvm-ar"},
        ["--cross", "--target-os", "linux", "--target-cpu", fake_machine],
    )

    print("OK")


if __name__ == "__main__":
    main()
