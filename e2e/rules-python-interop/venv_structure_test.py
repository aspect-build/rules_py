"""Asserts the tree shape py_venv builds over a rules_python runtime.

The venv is consumed as data, so assertions run against the built artifact
in runfiles: the relocatable pyvenv.cfg and the relative bin/python symlink
into the foreign runtime repo, plus a boot check that the symlinked
interpreter adopts the venv as its prefix.
"""

import os
import subprocess
import sys


def main() -> None:
    venv = os.path.join(
        os.environ["TEST_SRCDIR"], os.environ["TEST_WORKSPACE"], ".venv"
    )

    with open(os.path.join(venv, "pyvenv.cfg")) as f:
        cfg = dict(
            (key.strip(), value.strip())
            for key, value in (
                line.split("=", 1) for line in f if "=" in line
            )
        )
    # 3.12+ runtimes get the relocatable shape: prefix discovery starts from
    # the binary, so home stays empty even for a foreign runtime.
    assert cfg["home"] == "", cfg
    assert cfg["relocatable"] == "true", cfg
    assert cfg["version_info"].startswith("3.12."), cfg

    # The interpreter link must be relative (runfiles-relocatable) and land
    # in the rules_python-provisioned repo.
    # Resolve only the declared link (realpath would chase Bazel's
    # content-addressed repo cache, losing the repo directory).
    python = os.path.join(venv, "bin", "python")
    link = os.readlink(python)
    assert not os.path.isabs(link), link
    resolved = os.path.normpath(os.path.join(os.path.dirname(python), link))
    assert "rules_python++python+python_3_12" in resolved, resolved
    assert os.path.exists(resolved), resolved

    # The symlinked interpreter must boot with the venv as its prefix.
    probe = subprocess.run(
        [python, "-c", "import sys; print(sys.prefix); print(sys.version_info[:2])"],
        capture_output=True,
        text=True,
        check=True,
    )
    prefix, version = probe.stdout.splitlines()
    assert prefix.endswith(".venv"), probe.stdout
    assert version == "(3, 12)", probe.stdout

    print("OK")


main()
