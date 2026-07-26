"""Drive build_helper.py against rules_pycross's distutils probe sdist.

Ported from rules_pycross tests/e2e/build_setuptools (`distutils_probe/`,
`build_distutils_probe_sdist.py`, `test_distutils_probe.py`). The sdist's
`build_py` command shells out to a *fresh* interpreter and imports
`distutils.util`; on Python 3.12+ that only resolves when setuptools'
`_distutils_hack` is reachable from the child. A build action that exported a
stale `PYTHONPATH`/`PYTHONHOME` — the case build_helper.py's
`_INHERITED_PYTHON_ENV` filter exists for — breaks the child, not the parent,
so the failure is invisible to a plain "does it build" check.

Structured like `uv-sdist-mpicc`: the sdist is assembled in-process and
build_helper.py is invoked directly, so nothing is fetched from the network.
"""

import os
import subprocess
import sys
import tarfile
import tempfile
import textwrap

PYPROJECT = textwrap.dedent(
    """\
    [build-system]
    requires = ["setuptools", "wheel"]
    build-backend = "setuptools.build_meta"
    """
)

SETUP_PY = textwrap.dedent(
    """\
    import subprocess
    import sys

    from setuptools import setup
    from setuptools.command.build_py import build_py as _build_py


    class build_py(_build_py):
        def run(self):
            subprocess.check_call([sys.executable, "-c", "from distutils.util import byte_compile"])
            super().run()


    setup(
        name="distutils_probe",
        version="0.1",
        packages=["distutils_probe_pkg"],
        cmdclass={"build_py": build_py},
    )
    """
)


def find_build_helper() -> str:
    srcdir = os.environ["TEST_SRCDIR"]
    for root, _, files in os.walk(srcdir, followlinks=True):
        if "build_helper.py" in files and root.endswith(os.path.join("uv", "private", "pep517_whl")):
            return os.path.join(root, "build_helper.py")
    raise AssertionError("build_helper.py not found under TEST_SRCDIR")


def make_sdist(workdir: str) -> str:
    pkgdir = os.path.join(workdir, "distutils_probe-0.1")
    os.makedirs(os.path.join(pkgdir, "distutils_probe_pkg"))
    with open(os.path.join(pkgdir, "pyproject.toml"), "w") as f:
        f.write(PYPROJECT)
    with open(os.path.join(pkgdir, "setup.py"), "w") as f:
        f.write(SETUP_PY)
    with open(os.path.join(pkgdir, "distutils_probe_pkg", "__init__.py"), "w") as f:
        f.write("")
    sdist = os.path.join(workdir, "distutils_probe-0.1.tar.gz")
    with tarfile.open(sdist, "w:gz") as tar:
        tar.add(pkgdir, arcname="distutils_probe-0.1")
    return sdist


def main() -> None:
    helper = find_build_helper()
    tmp = tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR"))
    sdist = make_sdist(tmp)
    outdir = os.path.join(tmp, "out")

    result = subprocess.run(
        [sys.executable, helper, "--validate-anyarch", sdist, outdir],
        capture_output=True,
        text=True,
        env={
            "PATH": os.pathsep.join(["/usr/bin", "/bin"]),
            "HOME": os.environ.get("TEST_TMPDIR", "/tmp"),
        },
    )
    if result.returncode != 0:
        raise AssertionError(
            "build_helper failed:\nstdout:\n{}\nstderr:\n{}".format(result.stdout, result.stderr)
        )

    wheels = [f for f in os.listdir(outdir) if f.endswith(".whl")]
    assert wheels, "no wheel produced"
    print("OK: {}".format(wheels))


if __name__ == "__main__":
    main()
