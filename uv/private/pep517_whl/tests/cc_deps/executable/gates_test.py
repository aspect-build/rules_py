"""Runtime gate matrix + setup.cfg [build_ext] REPLACE-merge coverage.

Extends backend_gate_test.py's technique (run build_helper.py as a subprocess
against a synthetic sdist + crafted --cc-deps-info JSON) to the cc_deps runtime
gates that were previously untested, and to the DIST_EXTRA_CONFIG merge:

  * setup.cfg [build_ext] REPLACE-merge: the package's own link_objects /
    libraries values survive, PRECEDE ours, and include_dirs/define never leak
    into our generated cfg (the scariest silent failure would be dropped
    archives),
  * the DIST_EXTRA_CONFIG-preexists, SETUPTOOLS_USE_DISTUTILS=stdlib, whitespace,
    execroot-marker-survival, and setuptools-floor gates.

Each case asserts the gate's OWN message, so an unrelated exit 1 fails the test.

The subprocess env is built from scratch (PATH + a PYTHONPATH that only prepends
a controlled fake setuptools dist-info), so an ambient DIST_EXTRA_CONFIG /
SETUPTOOLS_USE_DISTUTILS on the host cannot perturb the helper. tomli still
resolves from this test's own venv (the runfiles interpreter), exactly as it
does for backend_gate_test.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tarfile
import tempfile

import runfiles

_MARKER = "__ASPECT_RULES_PY_EXECROOT__"
_HELPER = "_main/uv/private/pep517_whl/build_helper.py"


def _helper_path() -> str:
    r = runfiles.Create()
    helper = r.Rlocation(_HELPER)
    assert helper and os.path.isfile(helper), "build_helper.py missing: {}".format(helper)
    return helper


def _work(name: str) -> str:
    return tempfile.mkdtemp(prefix=name + "_", dir=os.environ["TEST_TMPDIR"])


def _setuptools_sdist(work: str, setup_cfg: str | None = None) -> str:
    """Write a minimal setuptools-backend sdist tar (single top-level `pkg/`)."""
    src = os.path.join(work, "src")
    os.makedirs(src)
    with open(os.path.join(src, "pyproject.toml"), "w") as f:
        f.write(
            "[build-system]\n"
            'requires = ["setuptools"]\n'
            'build-backend = "setuptools.build_meta"\n'
        )
    if setup_cfg is not None:
        with open(os.path.join(src, "setup.cfg"), "w") as f:
            f.write(setup_cfg)
    sdist = os.path.join(work, "sdist.tar")
    with tarfile.open(sdist, "w") as tar:
        tar.add(src, arcname="pkg")
    return sdist


def _fake_setuptools(work: str, version: str) -> str:
    """Create a bare `setuptools-<version>.dist-info` dir; return the parent path.

    importlib.metadata.version() only reads METADATA, so a standalone dist-info
    on sys.path is enough to drive the floor check to an exact version. Prepended
    to PYTHONPATH, it wins over any setuptools the interpreter might ship.
    """
    parent = os.path.join(work, "fake_sp")
    info = os.path.join(parent, "setuptools-{}.dist-info".format(version))
    os.makedirs(info)
    with open(os.path.join(info, "METADATA"), "w") as f:
        f.write("Metadata-Version: 2.1\nName: setuptools\nVersion: {}\n".format(version))
    return parent


def _info(work: str, **kwargs: list[str]) -> str:
    payload = {"compile_flags": [], "link_objects": [], "link_libraries": [], "link_flags": []}
    payload.update(kwargs)
    info = os.path.join(work, "cc_deps_info.json")
    with open(info, "w") as f:
        json.dump(payload, f)
    return info


def _env(fake_setuptools_dir: str | None = None, **extra: str) -> dict[str, str]:
    env = {"PATH": os.defpath}
    if fake_setuptools_dir:
        env["PYTHONPATH"] = fake_setuptools_dir
    env.update(extra)
    return env


def _run(
    helper: str,
    sdist: str,
    info: str,
    outdir: str,
    cwd: str,
    env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            helper,
            "--cc-deps-info", info,
            "--execroot-marker", _MARKER,
            sdist,
            outdir,
        ],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
    )


def _assert_gate(proc: subprocess.CompletedProcess[str], needle: str) -> None:
    assert proc.returncode == 1, \
        "expected exit 1, got {}; stderr:\n{}".format(proc.returncode, proc.stderr)
    assert needle in proc.stderr, \
        "expected gate message {!r}; stderr:\n{}".format(needle, proc.stderr)


def check_setup_cfg_replace_merge(helper: str) -> None:
    """G1: our generated [build_ext] cfg folds the package's values in front and
    never carries include_dirs/define. Read tmp_root's cfg after the (expected)
    build failure: build_helper writes it during env prep, before invoking
    `python -m build`, and leaves tmp_root behind when the build fails."""
    work = _work("g1")
    fake = _fake_setuptools(work, "70.0.0")
    setup_cfg = (
        "[build_ext]\n"
        "link_objects = pkg/vendor/libpkg.a\n"
        "libraries = pkgfoo\n"
        "include_dirs = pkg/include\n"
        "define = PKG_FLAG\n"
    )
    sdist = _setuptools_sdist(work, setup_cfg=setup_cfg)
    info = _info(
        work,
        compile_flags=["-I{}/gen/include".format(_MARKER), "-DOURDEF=1"],
        link_objects=["{}/gen/libdep.a".format(_MARKER)],
        link_libraries=["ourlib"],
    )
    outdir = os.path.join(work, "out")
    proc = _run(helper, sdist, info, outdir, cwd=work, env=_env(fake))

    # No `build` module in this bare env, so `python -m build` fails AFTER the
    # cfg is written; that non-zero exit is expected and confirms the write ran.
    assert proc.returncode == 1, \
        "expected the (post-cfg) build to fail; stderr:\n{}".format(proc.stderr)

    # DIST_EXTRA_CONFIG is set only in the child's build_env (not printed), so it
    # is not observable from here; assert the cfg exists at the documented
    # tmp_root path it would point at instead.
    cfg_path = os.path.join(os.path.abspath(outdir) + ".tmp", "cc_deps_extra.cfg")
    assert os.path.isfile(cfg_path), \
        "cc_deps_extra.cfg not written at {}; stderr:\n{}".format(cfg_path, proc.stderr)
    with open(cfg_path) as f:
        cfg = f.read()

    lines = cfg.splitlines()
    lo = next(line for line in lines if line.startswith("link_objects"))
    lib = next(line for line in lines if line.startswith("libraries"))

    # cwd == execroot here, so the marker expands to `work`.
    our_obj = "{}/gen/libdep.a".format(work)

    # (a) the package's own values are present and PRECEDE ours ...
    assert "pkg/vendor/libpkg.a" in lo and our_obj in lo, \
        "link_objects should carry both the package archive and ours; got {!r}".format(lo)
    assert lo.index("pkg/vendor/libpkg.a") < lo.index(our_obj), \
        "package link_objects should precede ours; got {!r}".format(lo)
    assert "pkgfoo" in lib and "ourlib" in lib, \
        "libraries should carry both the package lib and ours; got {!r}".format(lib)
    assert lib.index("pkgfoo") < lib.index("ourlib"), \
        "package libraries should precede ours; got {!r}".format(lib)

    # (b/c) include_dirs and define ride CPPFLAGS, never the cfg, so the package's
    # own include_dirs/define must NOT be echoed into our generated cfg.
    assert "include_dirs" not in cfg, "cfg must not carry include_dirs; got:\n{}".format(cfg)
    assert "define" not in cfg, "cfg must not carry define; got:\n{}".format(cfg)

    print("ok: setup.cfg [build_ext] REPLACE-merge folds package values in front")


def check_dist_extra_config_preexists(helper: str) -> None:
    """G4(i): a DIST_EXTRA_CONFIG already in the env is a hard error (v1 owns it)."""
    work = _work("g4_dec")
    fake = _fake_setuptools(work, "70.0.0")
    sdist = _setuptools_sdist(work)
    info = _info(work, link_objects=["{}/gen/libdep.a".format(_MARKER)])
    env = _env(fake, DIST_EXTRA_CONFIG=os.path.join(work, "user.cfg"))
    proc = _run(helper, sdist, info, os.path.join(work, "out"), cwd=work, env=env)
    _assert_gate(proc, "already set in the build environment")
    print("ok: pre-existing DIST_EXTRA_CONFIG rejected")


def check_use_distutils_stdlib(helper: str) -> None:
    """G4(ii): SETUPTOOLS_USE_DISTUTILS=stdlib disables the DIST_EXTRA_CONFIG path."""
    work = _work("g4_ud")
    fake = _fake_setuptools(work, "70.0.0")
    sdist = _setuptools_sdist(work)
    info = _info(work, link_objects=["{}/gen/libdep.a".format(_MARKER)])
    env = _env(fake, SETUPTOOLS_USE_DISTUTILS="stdlib")
    proc = _run(helper, sdist, info, os.path.join(work, "out"), cwd=work, env=env)
    _assert_gate(proc, "SETUPTOOLS_USE_DISTUTILS=stdlib is set")
    print("ok: SETUPTOOLS_USE_DISTUTILS=stdlib rejected")


def check_whitespace_guard(helper: str) -> None:
    """G4(iii): a whitespace-bearing link object is rejected, naming the path."""
    work = _work("g4_ws")
    fake = _fake_setuptools(work, "70.0.0")
    sdist = _setuptools_sdist(work)
    info = _info(work, link_objects=["{}/gen dir/libdep.a".format(_MARKER)])
    proc = _run(helper, sdist, info, os.path.join(work, "out"), cwd=work, env=_env(fake))
    _assert_gate(proc, "contains whitespace")
    assert "gen dir/libdep.a" in proc.stderr, \
        "whitespace error should name the offending path; stderr:\n{}".format(proc.stderr)
    print("ok: whitespace-bearing link object rejected, path named")


def check_framework_whitespace_guard(helper: str) -> None:
    """A whitespace-bearing framework (-F) search path is rejected, naming it.

    Apple `-F` paths ride CPPFLAGS, which is word-split downstream, so a spaced
    -F path is unrepresentable; it is caught by the same compile-path guard that
    covers -I/-iquote/-isystem."""
    work = _work("g4_fw")
    fake = _fake_setuptools(work, "70.0.0")
    sdist = _setuptools_sdist(work)
    info = _info(work, compile_flags=["-F{}/gen dir/Frameworks".format(_MARKER)])
    proc = _run(helper, sdist, info, os.path.join(work, "out"), cwd=work, env=_env(fake))
    _assert_gate(proc, "contains whitespace")
    assert "gen dir/Frameworks" in proc.stderr, \
        "framework whitespace error should name the offending path; stderr:\n{}".format(proc.stderr)
    print("ok: whitespace-bearing framework search path rejected, path named")


def check_link_flag_whitespace_guard(helper: str) -> None:
    """A whitespace-bearing link flag is rejected even when it is not an
    execroot-anchored path. LDFLAGS is word-split downstream, so no single flag
    can carry a space, regardless of where the space came from."""
    work = _work("g4_lf")
    fake = _fake_setuptools(work, "70.0.0")
    sdist = _setuptools_sdist(work)
    info = _info(work, link_flags=["-Wl,-rpath,/opt/my libs"])
    proc = _run(helper, sdist, info, os.path.join(work, "out"), cwd=work, env=_env(fake))
    _assert_gate(proc, "contains whitespace")
    assert "/opt/my libs" in proc.stderr, \
        "link-flag whitespace error should name the offending flag; stderr:\n{}".format(proc.stderr)
    print("ok: whitespace-bearing link flag rejected, flag named")


def check_marker_survival(helper: str) -> None:
    """G4(iv): if the execroot itself contains the marker token, substitution
    cannot complete and build_helper must fail rather than emit a corrupt path.
    Triggered honestly by running with a cwd whose path contains the marker."""
    parent = _work("g4_surv")
    work = os.path.join(parent, "dir_{}_here".format(_MARKER))
    os.makedirs(work)
    # No fake setuptools needed: this gate fires in _load_cc_deps_info, before
    # the backend/floor checks.
    sdist = _setuptools_sdist(work)
    info = _info(work, link_objects=["{}/gen/libdep.a".format(_MARKER)])
    proc = _run(helper, sdist, info, os.path.join(work, "out"), cwd=work, env=_env())
    _assert_gate(proc, "execroot marker survived substitution")
    print("ok: surviving execroot marker rejected")


def check_setuptools_floor(helper: str) -> None:
    """G4 floor gate: setuptools below the DIST_EXTRA_CONFIG floor (65.4.0) is a
    hard error. Driven by a fake old dist-info prepended to PYTHONPATH."""
    work = _work("g4_floor")
    fake = _fake_setuptools(work, "60.0.0")
    sdist = _setuptools_sdist(work)
    info = _info(work, link_objects=["{}/gen/libdep.a".format(_MARKER)])
    proc = _run(helper, sdist, info, os.path.join(work, "out"), cwd=work, env=_env(fake))
    _assert_gate(proc, "requires setuptools >= 65.4.0")
    assert "60.0.0" in proc.stderr, \
        "floor error should report the offending version; stderr:\n{}".format(proc.stderr)
    print("ok: sub-floor setuptools rejected")


def main() -> None:
    helper = _helper_path()
    check_setup_cfg_replace_merge(helper)
    check_dist_extra_config_preexists(helper)
    check_use_distutils_stdlib(helper)
    check_whitespace_guard(helper)
    check_framework_whitespace_guard(helper)
    check_link_flag_whitespace_guard(helper)
    check_marker_survival(helper)
    check_setuptools_floor(helper)
    print("ok: all cc_deps gate/merge cases fired")


if __name__ == "__main__":
    main()
