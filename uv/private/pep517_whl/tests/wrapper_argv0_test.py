import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

_SETUP_PY = """\
import os
import shlex
import subprocess

from setuptools import setup

cc = shlex.split(os.environ["CC"])
result = subprocess.run([*cc, "--version"], capture_output=True, text=True, check=True)
argv0 = result.stdout.strip()
expected = os.environ["CC_TEST_EXPECT_ARGV0"]
assert argv0 == expected, "driver saw argv[0] {!r}, expected {!r}".format(argv0, expected)

setup(name="argvprobe", version="1.0", py_modules=[])
"""


def _make_sdist(workdir: str) -> str:
    pkgdir = os.path.join(workdir, "argvprobe-1.0")
    os.makedirs(pkgdir)
    with open(os.path.join(pkgdir, "setup.py"), "w") as f:
        f.write(_SETUP_PY)
    sdist = os.path.join(workdir, "argvprobe-1.0.tar.gz")
    with tarfile.open(sdist, "w:gz") as archive:
        archive.add(pkgdir, arcname="argvprobe-1.0")
    return sdist


def main() -> None:
    workdir = tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"])
    sdist = _make_sdist(workdir)
    here = os.path.dirname(__file__)
    helper = os.path.join(here, "..", "build_helper.py")

    # The driver directory must remain absent from PATH to expose basename argv[0].
    drivers = os.path.join(workdir, "drivers")
    os.makedirs(drivers)
    driver = os.path.join(drivers, "fakecc")
    shutil.copy(os.path.join(here, "wrapper_argv0_fake_driver"), driver)
    os.chmod(driver, 0o755)

    outdir = os.path.join(workdir, "out")
    result = subprocess.run(
        [sys.executable, helper, sdist, outdir],
        capture_output=True,
        cwd=workdir,
        env={
            "CC": driver,
            "CC_TEST_EXPECT_ARGV0": driver,
            "HOME": workdir,
            "PATH": "/usr/bin:/bin",
        },
        text=True,
    )
    if result.returncode:
        raise AssertionError(
            "build_helper failed:\n{}\n{}".format(result.stdout, result.stderr)
        )


if __name__ == "__main__":
    main()
