"""Toolchain-derived path and flag resolution for venv assembly.

Encapsulates every value that depends on ``py_toolchain`` + ``ctx`` and
was formerly computed inline in ``assemble_venv``: version strings,
relative escape paths, the ``pyvenv.cfg`` home line, the ``bin/python``
symlink target, and the set of versioned python symlinks.

Extracted from the former ``venv.bzl`` monolith.
"""

load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")

def resolve_venv_toolchain(ctx, *, py_toolchain, is_windows, venv_name):
    """Compute toolchain-derived paths and flags for venv assembly.

    Args:
      ctx: The rule context.
      py_toolchain: Resolved Python toolchain struct from py_semantics.
      is_windows: Bool — whether the venv targets Windows.
      venv_name: The venv dir basename (e.g. ".safe_name").

    Returns:
      struct with:
        wheel_py_ver: lib dir name inside wheels (no freethreaded 't' suffix).
        venv_py_ver: lib dir name inside our venv (+ 't' if freethreaded).
        escape: relative path from site-packages dir up to runfiles root.
        venv_to_runfiles_escape: relative path from venv root up to runfiles root.
        site_packages_rel: site-packages path relative to venv root.
        pyvenv_home: ``home =`` line value for pyvenv.cfg.
        versioned_python_names: ``[python3, python3.X, python3.Xt?]``.
        bin_python_target_path: ``target_path`` for the ``bin/python`` symlink.
    """

    # py_ver controls two distinct layouts that agree most of the time
    # but diverge for freethreaded interpreters:
    #
    # * venv_py_ver — the lib-dir name inside OUR venv. Freethreaded
    #   Python 3.13+ (and onwards) expects its site-packages at
    #   `lib/python<M>.<m>t/site-packages/`. If we put ours at
    #   `python<M>.<m>/`, the interpreter never finds our symlinks.
    # * wheel_py_ver — the lib-dir name inside a wheel's `install_tree`.
    #   The unpacker hardcodes `lib/python<M>.<m>/site-packages/`
    #   regardless of freethreaded status (same wheel install layout for
    #   both non-t and t interpreters). Keep this without the `t`.
    wheel_py_ver = "python{}.{}".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    )
    venv_py_ver = wheel_py_ver + ("t" if py_toolchain.freethreaded else "")
    package_depth = len(ctx.label.package.split("/")) if ctx.label.package else 0

    # From .pth / symlink dir up to runfiles root.
    # Components: 1 workspace + N package + 1 venv + 3 (lib, pythonX.Y, site-packages)
    escape_count = 1 + package_depth + 1 + 3
    escape = "/".join([".."] * escape_count)

    # From venv root (= sys.prefix at runtime) up to runfiles root.
    venv_to_runfiles_escape = "/".join([".."] * (2 + package_depth))

    site_packages_rel = "{}/lib/{}/site-packages".format(venv_name, venv_py_ver)

    # `relocatable = true` below is a rules_py extension: for an in-build
    # CPython 3.11/3.12 runtime that supports build-time venvs, keep `home`
    # empty so getpath resolves the relocatable bin/python symlink into the
    # base executable without forcing prefix discovery from a relative path.
    # Omitting the key leaves sys._base_executable at the outer venv symlink,
    # so a stdlib-created nested venv writes the outer venv's bin/ as home.
    # A relative `home` instead resolves from the startup cwd:
    # https://github.com/python/cpython/blob/3bb231a6/Modules/getpath.py#L362-L365
    # https://github.com/python/cpython/blob/3bb231a6/Modules/getpath.py#L431-L432
    # https://github.com/python/cpython/blob/3bb231a6/Lib/venv/__init__.py#L158-L166
    # Direct runtimes use that symlink. The capability also permits wrappers
    # that set PYTHONEXECUTABLE to preserve the underlying base executable:
    # https://github.com/bazel-contrib/rules_python/blob/bac54949/python/private/py_runtime_info.bzl#L316-L337
    use_empty_venv_home = (
        py_toolchain.runfiles_interpreter and
        not is_windows and
        getattr(py_toolchain.toolchain, "implementation_name", None) == "cpython" and
        getattr(py_toolchain.toolchain, "supports_build_time_venv", False) and
        py_toolchain.interpreter_version_info.major == 3 and
        py_toolchain.interpreter_version_info.minor in [11, 12]
    )
    if use_empty_venv_home:
        pyvenv_home = ""
    elif py_toolchain.runfiles_interpreter:
        pbs_rlocation = to_rlocation_path(ctx, py_toolchain.python)
        pbs_bin_dir = "/".join(pbs_rlocation.split("/")[:-1])
        pyvenv_home = "{}/{}".format(venv_to_runfiles_escape, pbs_bin_dir)
    else:
        pyvenv_home = py_toolchain.python.path.rsplit("/", 1)[0]

    # Versioned python symlinks: python3, python3.<MAJ>.<MIN>, and on
    # freethreaded interpreters also python3.<MAJ>.<MIN>t (the name the
    # interpreter looks itself up under). All point at the sibling `python`.
    versioned_python_names = [
        "python{}".format(py_toolchain.interpreter_version_info.major),
        "python{}.{}".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
        ),
    ]
    if py_toolchain.freethreaded:
        versioned_python_names.append("python{}.{}t".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
        ))

    # bin/python — the symlink the launcher exec's and that Python reads
    # to compute sys.base_prefix. We emit an UNRESOLVED symlink
    # (`declare_symlink` + `target_path`) with an explicit relative
    # target rather than a `declare_file` + `target_file` on
    # `py_toolchain.python` for two reasons:
    #
    #  1. `target_file` lets Bazel pick the symlink target, and the
    #     choice differs across Bazel versions (Bazel 8 tends to write
    #     relative, Bazel 9 absolute). Downstream tools that repack the
    #     tar (`py_image_layer`) need a stable, runfiles-correct target.
    #  2. Absolute targets bake in the build-host execroot path — in an
    #     OCI container that path doesn't exist, bin/python becomes a
    #     dangling symlink, Python falls back to its compile-time
    #     `/install` base_prefix, then fails to locate the stdlib.
    #
    # From `<venv>/bin/`, walk up to the runfiles root (`.runfiles/`)
    # and then down through the interpreter's rlocation path.
    # Up count: 1 (bin) + 1 (venv) + package_depth + 1 (workspace) = 3 + pkg.
    # For system-interpreter (no runfiles_interpreter), fall back to the
    # absolute path — these are already non-hermetic by construction.
    if py_toolchain.runfiles_interpreter:
        bin_to_runfiles_root = "/".join([".."] * (3 + package_depth))
        bin_python_target_path = "{}/{}".format(
            bin_to_runfiles_root,
            to_rlocation_path(ctx, py_toolchain.python),
        )
    else:
        bin_python_target_path = py_toolchain.python.path

    return struct(
        wheel_py_ver = wheel_py_ver,
        venv_py_ver = venv_py_ver,
        escape = escape,
        venv_to_runfiles_escape = venv_to_runfiles_escape,
        site_packages_rel = site_packages_rel,
        pyvenv_home = pyvenv_home,
        versioned_python_names = versioned_python_names,
        bin_python_target_path = bin_python_target_path,
    )
