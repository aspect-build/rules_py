"""Toolchain-derived path and flag resolution for venv assembly."""

load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")

def _relative_up(depth):
    """Join ``depth`` repetitions of ``..`` into a single relative path."""
    return "/".join([".."] * depth)

def _package_depth(ctx):
    """Count the ``/``-separated segments in the target's Bazel package."""
    return len(ctx.label.package.split("/")) if ctx.label.package else 0

def _py_versions(py_toolchain):
    """Compute the ``lib/`` directory names used by wheels and the venv.

    Wheels always use ``python<MAJ>.<MIN>`` regardless of freethreaded
    status — the unpacker hardcodes this layout. Freethreaded CPython
    3.13+ expects site-packages under ``python<MAJ>.<MIN>t/``, so the
    venv directory name carries the ``t`` suffix when applicable.

    Returns:
      ``(wheel_py_ver, venv_py_ver)``
    """
    base = "python{}.{}".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    )
    return base, base + ("t" if py_toolchain.freethreaded else "")

def _site_packages_escape(package_depth):
    """Relative path from ``<venv>/lib/pythonX.Y/site-packages/`` to the
    runfiles root.

    Ascends: workspace (1) + package segments (N) + venv dir (1) +
    lib/pythonX.Y/site-packages (3) = 5 + N.
    """
    return _relative_up(5 + package_depth)

def _venv_root_escape(package_depth):
    """Relative path from the venv root (``sys.prefix``) to the runfiles
    root.

    Ascends: workspace (1) + package segments (N) + venv dir (1) = 2 + N.
    """
    return _relative_up(2 + package_depth)

def _uses_empty_venv_home(py_toolchain, is_windows):
    """Whether to leave ``home`` empty in ``pyvenv.cfg``.

    CPython 3.11/3.12 runfiles interpreters with build-time venv support
    on non-Windows resolve a relocatable ``bin/python`` symlink correctly
    only when ``home`` is empty and ``relocatable = true``. With a
    non-empty relative ``home``, ``getpath.py`` resolves from the startup
    cwd, which breaks under sandbox/RBE where the cwd is not the
    execroot.

    Omitting the key entirely leaves ``sys._base_executable`` at the
    outer venv symlink, so a stdlib-created nested venv writes the outer
    venv's ``bin/`` as ``home`` — also incorrect.

    See ``getpath.py`` L362-365, L431-432 and ``Lib/venv/__init__.py``
    L158-166:
    https://github.com/python/cpython/blob/3bb231a6/Modules/getpath.py#L362-L365
    """
    return (
        py_toolchain.runfiles_interpreter and
        not is_windows and
        getattr(py_toolchain.toolchain, "implementation_name", None) == "cpython" and
        getattr(py_toolchain.toolchain, "supports_build_time_venv", False) and
        py_toolchain.interpreter_version_info.major == 3 and
        py_toolchain.interpreter_version_info.minor in [11, 12]
    )

def _pyvenv_home(ctx, py_toolchain, is_windows, venv_root_escape):
    """Resolve the ``home =`` line for ``pyvenv.cfg``.

    Three branches:

    - Empty for qualifying CPython 3.11/3.12 (see ``_uses_empty_venv_home``).
    - A venv-root-relative path to the interpreter's ``bin/`` for other
      runfiles interpreters.
    - The absolute filesystem path for system interpreters (already
      non-hermetic by construction).
    """
    if _uses_empty_venv_home(py_toolchain, is_windows):
        return ""
    if py_toolchain.runfiles_interpreter:
        interpreter_rlocation = to_rlocation_path(ctx, py_toolchain.python)
        interpreter_bin_dir = "/".join(interpreter_rlocation.split("/")[:-1])
        return "{}/{}".format(venv_root_escape, interpreter_bin_dir)
    return py_toolchain.python.path.rsplit("/", 1)[0]

def _versioned_python_names(py_toolchain):
    """Symlink names under which CPython looks itself up.

    ``python3``, ``python3.<MIN>``, and ``python3.<MIN>t`` for
    freethreaded builds. All point at the sibling ``python`` symlink.
    """
    major = py_toolchain.interpreter_version_info.major
    minor = py_toolchain.interpreter_version_info.minor
    names = ["python{}".format(major), "python{}.{}".format(major, minor)]
    if py_toolchain.freethreaded:
        names.append("python{}.{}t".format(major, minor))
    return names

def _bin_python_target_path(ctx, py_toolchain, package_depth):
    """Compute the ``target_path`` for the ``bin/python`` unresolved
    symlink.

    Uses an explicit relative path through the runfiles tree instead of
    Bazel's ``target_file`` mechanism. ``target_file`` lets Bazel choose
    the symlink target, and the choice (relative vs absolute) differs
    across Bazel versions — Bazel 8 tends relative, Bazel 9 absolute.
    Absolute targets bake in the build-host execroot path, which does
    not exist inside an OCI container, leaving ``bin/python`` as a
    dangling symlink.

    From ``<venv>/bin/``, ascends bin (1) + venv (1) + package (N) +
    workspace (1) = 3 + N, then descends into the interpreter's
    rlocation path. System interpreters fall back to the absolute path.
    """
    if not py_toolchain.runfiles_interpreter:
        return py_toolchain.python.path
    return "{}/{}".format(
        _relative_up(3 + package_depth),
        to_rlocation_path(ctx, py_toolchain.python),
    )

def resolve_venv_toolchain(ctx, *, py_toolchain, is_windows, venv_name):
    """Compute toolchain-derived paths and flags for venv assembly.

    Args:
      ctx: The rule context.
      py_toolchain: Resolved Python toolchain struct from py_semantics.
      is_windows: Whether the venv targets Windows.
      venv_name: The venv dir basename (e.g. ``.safe_name``).

    Returns:
      struct with ``wheel_py_ver``, ``venv_py_ver``, ``escape``,
      ``venv_to_runfiles_escape``, ``site_packages_rel``,
      ``pyvenv_home``, ``versioned_python_names``,
      ``bin_python_target_path``.
    """
    wheel_py_ver, venv_py_ver = _py_versions(py_toolchain)
    depth = _package_depth(ctx)
    venv_to_runfiles_escape = _venv_root_escape(depth)

    return struct(
        wheel_py_ver = wheel_py_ver,
        venv_py_ver = venv_py_ver,
        escape = _site_packages_escape(depth),
        venv_to_runfiles_escape = venv_to_runfiles_escape,
        site_packages_rel = "{}/lib/{}/site-packages".format(venv_name, venv_py_ver),
        pyvenv_home = _pyvenv_home(ctx, py_toolchain, is_windows, venv_to_runfiles_escape),
        versioned_python_names = _versioned_python_names(py_toolchain),
        bin_python_target_path = _bin_python_target_path(ctx, py_toolchain, depth),
    )
