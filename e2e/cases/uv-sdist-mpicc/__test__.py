"""Drive build_helper.py against a synthetic sdist whose setup.py asserts
the MPICC contract: resolved from the system PATH when an mpicc exists
there, left unset otherwise. mpi4py consults $MPICC before searching
PATH, so a bogus default (e.g. the Bazel C compiler) breaks its build.
"""

import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap

SETUP_PY = textwrap.dedent(
    """\
    import os
    import shlex
    import subprocess

    from setuptools import setup

    expect = os.environ["MPICC_TEST_EXPECT"]
    mpicc = os.environ.get("MPICC")

    if expect == "system":
        if not mpicc:
            raise SystemExit("MPICC is unset; expected it to resolve to the system mpicc")
        out = subprocess.run(
            [shlex.split(mpicc)[0], "--version"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        if "FAKE-SYSTEM-MPICC" not in out:
            raise SystemExit("MPICC does not invoke the system mpicc; --version said: " + out)
    elif expect == "unset":
        if mpicc:
            raise SystemExit("MPICC unexpectedly set to: " + mpicc)

    setup(name="mpitest", version="1.0", py_modules=[])
    """
)

FAKE_MPICC = textwrap.dedent(
    """\
    #!/bin/sh
    for arg in "$@"; do
        if [ "$arg" = "--version" ]; then
            echo "FAKE-SYSTEM-MPICC 1.0"
            exit 0
        fi
    done
    exit 1
    """
)


def find_build_helper():
    srcdir = os.environ["TEST_SRCDIR"]
    for root, _, files in os.walk(srcdir, followlinks=True):
        if "build_helper.py" in files and root.endswith(os.path.join("uv", "private", "pep517_whl")):
            return os.path.join(root, "build_helper.py")
    raise AssertionError("build_helper.py not found under TEST_SRCDIR")


def make_sdist(workdir):
    pkgdir = os.path.join(workdir, "mpitest-1.0")
    os.makedirs(pkgdir)
    with open(os.path.join(pkgdir, "setup.py"), "w") as f:
        f.write(SETUP_PY)
    sdist = os.path.join(workdir, "mpitest-1.0.tar.gz")
    with tarfile.open(sdist, "w:gz") as tar:
        tar.add(pkgdir, arcname="mpitest-1.0")
    return sdist


def run_helper(helper, sdist, outdir, path_entries, expect):
    rules_py_root = os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.dirname(helper)))
    )
    env = {
        "MPICC_TEST_EXPECT": expect,
        "PATH": os.pathsep.join(path_entries),
        "HOME": os.environ.get("TEST_TMPDIR", "/tmp"),
        "PYTHONPATH": rules_py_root,
    }
    cc = shutil.which("cc") or "/usr/bin/cc"
    if os.path.exists(cc):
        env["CC"] = cc
    result = subprocess.run(
        [sys.executable, helper, sdist, outdir],
        capture_output=True,
        text=True,
        env=env,
    )
    if result.returncode != 0:
        raise AssertionError(
            "build_helper failed for expect={}:\nstdout:\n{}\nstderr:\n{}".format(
                expect, result.stdout, result.stderr
            )
        )
    wheels = [f for f in os.listdir(outdir) if f.endswith(".whl")]
    assert wheels, "no wheel produced for expect={}".format(expect)


def main():
    helper = find_build_helper()
    tmp = tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR"))
    sdist = make_sdist(tmp)
    system_path = ["/usr/bin", "/bin"]

    fakebin = os.path.join(tmp, "fakebin")
    os.makedirs(fakebin)
    fake_mpicc = os.path.join(fakebin, "mpicc")
    with open(fake_mpicc, "w") as f:
        f.write(FAKE_MPICC)
    os.chmod(fake_mpicc, 0o755)

    run_helper(helper, sdist, os.path.join(tmp, "out-system"), [fakebin] + system_path, "system")

    if not any(os.path.exists(os.path.join(d, "mpicc")) for d in system_path):
        run_helper(helper, sdist, os.path.join(tmp, "out-unset"), system_path, "unset")

    print("OK")


if __name__ == "__main__":
    main()
