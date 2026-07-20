"""Venv / interpreter layout assertions for e2e tests.

Add `//tools/verify_venv` to a `py_binary`'s `deps`, then call the
relevant check (or `verify_all()`) inside the entry script. Each
assertion raises AssertionError with enough detail to localise a
regression.

Checks exposed:

  * verify_interpreter_symlinks()      — the interpreter's `bin/` reached
                                          via `sys.executable` has exactly
                                          one real `python3.<minor>` binary,
                                          with `python` and `python3` as
                                          symlinks resolving to it.

  * verify_no_dangling_symlinks(root)  — every symlink under `root`
                                          (default: `sys.prefix`) resolves
                                          to an existing path. Catches the
                                          class of regression where layer
                                          packaging emits literal symlink
                                          targets that don't exist inside
                                          the container.

  * verify_in_venv()                   — `sys.base_prefix != sys.prefix`.
                                          The binary is actually running
                                          in its own venv, not the base
                                          Python install.

  * verify_sys_path()                  — every non-empty entry on
                                          `sys.path` exists (tolerating
                                          the speculative `python<x>.zip`
                                          stubs Python adds without
                                          guaranteeing them).

  * verify_imports(packages)           — each named package imports and
                                          exposes a non-None `__file__`.
                                          A package falling back to the
                                          namespace-package shape (e.g.
                                          because its `__init__.py`
                                          dangles) has `__file__ is None`
                                          — exactly the symptom of the
                                          original wheel-symlink bug.

  * verify_all(imports=())             — runs every check above, with
                                          `imports` passed through to
                                          `verify_imports`.

Designed to run two ways:

  * Directly as a py_test on the host (`bazel test :verify_venv_test`) —
    exercises the runfiles-tree layout the default toolchain ships.
  * Inlined into a py_binary's `__main__.py` so the same assertion runs
    inside the OCI container under `container_structure_test`.
"""

import glob
import importlib
import os
import sys
from typing import Iterable, Optional


def verify_interpreter_symlinks() -> None:
    bin_dir = os.path.dirname(os.path.realpath(sys.executable))
    candidates = []
    for name in ("python", "python3"):
        p = os.path.join(bin_dir, name)
        if os.path.lexists(p):
            candidates.append(p)
    candidates.extend(glob.glob(os.path.join(bin_dir, "python3.*[0-9]")))

    real = [p for p in candidates if not os.path.islink(p)]
    links = [p for p in candidates if os.path.islink(p)]

    assert len(real) == 1, (
        f"want exactly 1 real interpreter binary in {bin_dir}, "
        f"got {len(real)}: {real}"
    )
    assert len(links) >= 2, (
        f"want >=2 python* symlinks in {bin_dir}, "
        f"got {len(links)}: {links}"
    )
    for s in links:
        target = os.path.realpath(s)
        assert target == real[0], (
            f"symlink {s} resolves to {target}, expected {real[0]}"
        )


def verify_no_dangling_symlinks(root: Optional[str] = None) -> None:
    if root is None:
        root = sys.prefix
    dangling = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames + dirnames:
            p = os.path.join(dirpath, name)
            if os.path.islink(p) and not os.path.exists(p):
                dangling.append((p, os.readlink(p)))
    assert not dangling, (
        f"{len(dangling)} dangling symlink(s) under {root}:\n"
        + "\n".join(f"  {p} -> {t}" for p, t in dangling[:10])
        + ("\n  ..." if len(dangling) > 10 else "")
    )


def verify_in_venv() -> None:
    assert sys.base_prefix != sys.prefix, (
        f"not running in a venv: sys.base_prefix == sys.prefix == {sys.prefix}"
    )


def verify_base_prefix() -> None:
    """sys.base_prefix must not be the PBS compile-time /install sentinel."""
    assert sys.base_prefix != "/install", (
        f"sys.base_prefix is '/install' (the PBS compile-time prefix) instead of "
        f"the real interpreter installation. Python {sys.version} failed to resolve "
        f"the runfiles symlink chain in pyvenv.cfg's home= key."
    )
    assert os.path.isdir(sys.base_prefix), (
        f"sys.base_prefix={sys.base_prefix!r} does not exist on disk"
    )
    stdlib_dir = os.path.join(
        sys.base_prefix,
        "lib",
        f"python{sys.version_info.major}.{sys.version_info.minor}",
    )
    assert os.path.isdir(stdlib_dir), (
        f"stdlib not found at {stdlib_dir!r} (sys.base_prefix={sys.base_prefix!r})"
    )


def verify_sys_path() -> None:
    missing = []
    for p in sys.path:
        if not p:
            continue  # The empty entry means "current working directory".
        if os.path.exists(p):
            continue
        # Python prepends `pythonX.Y.zip` to sys.path speculatively; the
        # file doesn't have to exist on disk for stdlib lookups to work.
        if p.endswith(".zip"):
            continue
        missing.append(p)
    assert not missing, (
        "missing sys.path entries:\n" + "\n".join(f"  {p}" for p in missing)
    )


def verify_imports(packages: Iterable[str]) -> None:
    for name in packages:
        mod = importlib.import_module(name)
        path = getattr(mod, "__file__", None)
        assert path is not None, (
            f"{name} imported as a namespace package (likely __init__.py "
            f"is unreadable or missing — chase the underlying symlinks)"
        )


def verify_all(imports: Iterable[str] = ()) -> None:
    verify_interpreter_symlinks()
    verify_no_dangling_symlinks()
    verify_in_venv()
    verify_base_prefix()
    verify_sys_path()
    verify_imports(imports)


if __name__ == "__main__":
    verify_all()
    print(
        f"verify_venv: ok bin_dir={os.path.dirname(os.path.realpath(sys.executable))}"
    )
