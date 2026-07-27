"""Runtime gate: build_helper.py must refuse cc_deps on a non-setuptools backend.

cc_deps injects setuptools [build_ext] settings that other PEP 517 backends
ignore, so silently dropping the inputs would produce a wheel that fails to
link at import time. build_helper must instead fail fast with an actionable
message. This runs build_helper.py directly as a subprocess against a synthetic
sdist whose declared backend is not setuptools, plus a crafted cc-deps params
file, and asserts exit 1 with the backend-gate message.
"""

import json
import os
import subprocess
import sys
import tarfile
import tempfile

import runfiles

_MARKER = "__ASPECT_RULES_PY_EXECROOT__"
_HELPER = "_main/uv/private/pep517_whl/build_helper.py"


def main() -> None:
    r = runfiles.Create()
    helper = r.Rlocation(_HELPER)
    assert helper and os.path.isfile(helper), "build_helper.py missing: {}".format(helper)

    work = tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"])

    # A synthetic sdist whose backend is deliberately not setuptools.
    src_dir = os.path.join(work, "pkg")
    os.makedirs(src_dir)
    with open(os.path.join(src_dir, "pyproject.toml"), "w") as f:
        f.write(
            "[build-system]\n"
            "requires = []\n"
            'build-backend = "not_setuptools.api"\n'
            'backend-path = ["."]\n'
        )
    sdist = os.path.join(work, "sdist.tar.gz")
    with tarfile.open(sdist, "w:gz") as tar:
        tar.add(src_dir, arcname="pkg")

    # A minimal but non-empty cc-deps params file: cc_deps is present, so the
    # gate must fire rather than no-op.
    info = os.path.join(work, "cc_deps_info.json")
    with open(info, "w") as f:
        json.dump(
            {
                "compile_flags": ["-I{}/some/include".format(_MARKER)],
                "link_objects": ["{}/some/libdep.a".format(_MARKER)],
                "link_libraries": [],
                "link_flags": [],
            },
            f,
        )

    outdir = os.path.join(work, "out")

    # Deterministic by construction: a minimal env built from scratch (not a
    # filtered copy of os.environ), so an ambient DIST_EXTRA_CONFIG or
    # SETUPTOOLS_USE_DISTUTILS on the host cannot perturb the helper. The gate
    # path needs no host tools; build_helper falls back to os.defpath itself.
    subprocess_env = {"PATH": os.defpath}

    proc = subprocess.run(
        [
            sys.executable,
            helper,
            "--cc-deps-info", info,
            "--execroot-marker", _MARKER,
            sdist,
            outdir,
        ],
        cwd=work,
        env=subprocess_env,
        capture_output=True,
        text=True,
    )

    assert proc.returncode == 1, \
        "expected exit 1, got {}; stderr:\n{}".format(proc.returncode, proc.stderr)
    assert "cc_deps is only supported with the setuptools build backend" in proc.stderr, \
        "missing backend-gate error; stderr:\n{}".format(proc.stderr)
    assert "not_setuptools.api" in proc.stderr, \
        "error should name the offending backend; stderr:\n{}".format(proc.stderr)

    print("ok: backend gate fired with exit 1")


if __name__ == "__main__":
    main()
