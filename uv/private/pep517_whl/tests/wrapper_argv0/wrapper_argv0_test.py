import os
import shlex
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

def check_compiler(name):
    compiler = shlex.split(os.environ[name])
    result = subprocess.run([*compiler, "--version"], capture_output=True, text=True, check=True)
    argv0 = result.stdout.strip()
    expected = os.environ["CC_TEST_EXPECT_{}_ARGV0".format(name)]
    assert argv0 == expected, "{} driver saw argv[0] {!r}, expected {!r}".format(name, argv0, expected)


check_compiler("CC")
check_compiler("CXX")

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
    helper = os.path.join(here, "..", "..", "tools", "build_helper.py")

    # The driver directory must remain absent from PATH to expose basename argv[0].
    drivers = os.path.join(workdir, "drivers")
    os.makedirs(drivers)
    cc_driver = os.path.join(drivers, "fakecc")
    cxx_driver = os.path.join(drivers, "fakecxx")
    for driver in (cc_driver, cxx_driver):
        shutil.copy(os.path.join(here, "wrapper_argv0_fake_driver"), driver)
        os.chmod(driver, 0o755)

    preserved_flag = "--wrapper-argv0-test-flag"

    outdir = os.path.join(workdir, "out")
    result = subprocess.run(
        [sys.executable, helper, sdist, outdir],
        capture_output=True,
        cwd=workdir,
        env={
            "CC": shlex.join([cc_driver, preserved_flag]),
            "CC_TEST_EXPECT_CC_ARGV0": cc_driver,
            "CC_TEST_EXPECT_CXX_ARGV0": cxx_driver,
            "CC_TEST_EXPECT_FLAG": preserved_flag,
            "CXX": shlex.join([cxx_driver, preserved_flag]),
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
