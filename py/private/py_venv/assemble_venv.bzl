"""Build-time assembly of a Python virtualenv via ctx.actions.symlink + write.

This module is the single place in rules_py that declares the files making
up a Python venv. Both ``py_binary`` / ``py_test`` (each with its own
internal venv, unless ``expose_venv = True`` routes them to a sibling
py_venv) and the standalone ``py_venv`` rule call ``assemble_venv`` to
keep their layouts bit-identical.

The venv shape mirrors what CPython's ``python -m venv`` + pip install
produces, so downstream tools (IDEs, ``$VIRTUAL_ENV``-aware shells,
distutils, etc.) treat it as a real venv:

    <venv_name>/
      pyvenv.cfg
      bin/
        python                                  symlink -> py_toolchain.python
        python3                                 symlink -> python
        python3.<MAJ>.<MIN>                     symlink -> python
        activate                                bash/zsh activation script
        <console_script>                        one per wheel-declared entry point
      lib/python<MAJ>.<MIN>/site-packages/
        <name>.pth                              first-party + fallback .pth
        _virtualenv.py                          distutils-compat shim
        _virtualenv.pth                         loads the shim at site init
        <top_level>                             symlink to a wheel's subdir
        <ns_pkg>/<entry>                        merged PEP 420 namespace
        <dist>-<ver>.dist-info                  symlink when the wheel needs no
                                                whole-wheel fallback

The whole tree is declared at analysis time as individual
``ctx.actions.declare_file`` / ``ctx.actions.declare_symlink`` outputs so
Bazel's action cache treats each piece independently (no tree-artifact
+ remote-exec materialisation surprises).
"""

load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN")
load(":toolchains_resolver.bzl", "resolve_venv_toolchain")
load(":virtuals_resolvers.bzl", "resolve_wheel_collisions")

def _dict_to_exports(env):
    """Render an env dict as ``export KEY="VALUE"`` shell lines."""
    return ["export %s=\"%s\"" % (k, v) for (k, v) in env.items()]

def _build_wheel_lookups(wheels):
    """Build ``install_tree`` and known-layout lookups in a single pass.

    Returns ``(tree_by_sp, known_layout_site_pkgs)``:

    * ``tree_by_sp`` maps each wheel's ``site_packages_rfpath`` to its
      ``install_tree`` File, consumed by ``PySiteMerge`` actions.
    * ``known_layout_site_pkgs`` flags wheels that declare ``top_levels``,
      so ``_make_pth_formatter`` can emit plain path lines for them and
      reserve ``site.addsitedir`` for layout-unknown wheels.
    """
    tree_by_sp = {}
    known_layout = {}
    for w in wheels:
        sp = w.site_packages_rfpath
        tree_by_sp[sp] = w.install_tree
        if w.top_levels:
            known_layout[sp] = True
    return tree_by_sp, known_layout

def _make_pth_formatter(fully_covered, known_layout, escape, venv_escape):
    """Build a ``map_each`` closure for ``.pth`` import formatting.

    Three branches per import path:

    * Fully covered wheel → ``None`` (omitted from the ``.pth``).
    * Layout-unknown wheel whose path ends in ``site-packages`` →
      ``site.addsitedir`` with a ``sys.prefix``-relative path that
      survives RBE sandbox layouts.
    * Everything else → plain relative escape + import path.
    """

    def _format_imp(imp):
        if imp in fully_covered:
            return None
        if imp.endswith("site-packages") and imp not in known_layout:
            return ("import os, sys, site; " +
                    "site.addsitedir(os.path.normpath(os.path.join(" +
                    "sys.prefix, \"{}\", \"{}\")))").format(venv_escape, imp)
        return "{}/{}".format(escape, imp)

    return _format_imp

def _declare_toplevel_symlinks(ctx, top_level_to_site_pkgs, tc, declared):
    """Declare per-top-level site-packages symlinks into owning wheels.

    Each symlink escapes from ``site-packages/`` up to the runfiles root,
    then descends into the owning wheel's ``site_packages_rfpath``.
    ``/``-joined top-levels (merged namespace packages, e.g.
    ``jaraco/functools``) get one extra ``../`` per segment.  A per-wheel
    prefix cache avoids recomputing the escape path.
    """
    prefix = tc.site_packages_rel + "/"
    target_prefix_by_sp = {}
    for tl, wheel_sp in top_level_to_site_pkgs.items():
        out = ctx.actions.declare_symlink(prefix + tl)
        target_prefix = target_prefix_by_sp.get(wheel_sp)
        if target_prefix == None:
            target_prefix = tc.escape + "/" + wheel_sp + "/"
            target_prefix_by_sp[wheel_sp] = target_prefix
        target_path = target_prefix + tl
        if "/" in tl:
            target_path = "../" * tl.count("/") + target_path
        ctx.actions.symlink(output = out, target_path = target_path)
        declared.append(out)

def _run_site_merges(
        ctx,
        merge_groups,
        tree_by_sp,
        tc,
        site_merge_script_py,
        package_collisions,
        exec_runtime,
        declared):
    """Run ``PySiteMerge`` actions for physical package merges.

    Each group's subtree is copied from every contributing wheel into a
    real directory inside site-packages — the layout a flat ``pip install``
    produces.  The venv's own site-packages precedes per-wheel ``.pth``
    entries on ``sys.path``, so the merged copy is what Python binds the
    regular package's ``__path__`` to; per-wheel originals are shadowed.
    """
    for group in merge_groups:
        merged_dir = ctx.actions.declare_directory(
            "{}/{}".format(tc.site_packages_rel, group.root),
        )
        arguments = ctx.actions.args()
        arguments.add(site_merge_script_py)
        arguments.add_all([merged_dir], expand_directories = False, before_each = "--into")
        arguments.add("--collision-policy", package_collisions)
        trees = []
        for sp in group.site_packages_list:
            tree = tree_by_sp[sp]
            trees.append(tree)
            arguments.add_all(
                [tree],
                expand_directories = False,
                before_each = "--src",
                format_each = "%s/lib/{}/site-packages/{}".format(tc.wheel_py_ver, group.root),
            )
        ctx.actions.run(
            mnemonic = "PySiteMerge",
            executable = exec_runtime.interpreter,
            toolchain = EXEC_TOOLS_TOOLCHAIN,
            arguments = [arguments],
            inputs = depset(
                direct = [site_merge_script_py] + trees,
                transitive = [exec_runtime.files],
            ),
            outputs = [merged_dir],
            execution_requirements = {"supports-path-mapping": "1"},
        )
        declared.append(merged_dir)

def _declare_pth_file(ctx, imports_depset, format_imp, tc, safe_name, declared):
    """Generate the ``.pth`` file for first-party and fallback imports.

    Uses ``map_each`` with ``allow_closure`` so the imports depset is
    consumed at execution time (param-file writing), not at analysis
    time — avoiding an unnecessary ``.to_list()``.
    """
    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")
    pth_lines.add(tc.escape)
    pth_lines.add_all(imports_depset, map_each = format_imp, allow_closure = True)

    out = ctx.actions.declare_file(
        "{}/{}.pth".format(tc.site_packages_rel, safe_name),
    )
    ctx.actions.write(output = out, content = pth_lines)
    declared.append(out)

def _declare_pyvenv_cfg(
        ctx,
        tc,
        py_toolchain,
        venv_name,
        include_system,
        include_user,
        declared):
    """Write ``pyvenv.cfg`` with version, home, and site-packages flags."""
    home_line = "home =\n" if tc.pyvenv_home == "" else "home = {}\n".format(tc.pyvenv_home)
    out = ctx.actions.declare_file("{}/pyvenv.cfg".format(venv_name))
    ctx.actions.write(
        output = out,
        content = home_line + (
            "implementation = CPython\n" +
            "version_info = {major}.{minor}.{micro}\n" +
            "include-system-site-packages = {include_system}\n" +
            "aspect-include-user-site-packages = {include_user}\n" +
            "relocatable = true\n"
        ).format(
            major = py_toolchain.interpreter_version_info.major,
            minor = py_toolchain.interpreter_version_info.minor,
            micro = py_toolchain.interpreter_version_info.micro,
            include_system = str(include_system).lower(),
            include_user = str(include_user).lower(),
        ),
    )
    declared.append(out)

def _declare_python_bin(ctx, tc, venv_name, declared):
    """Declare ``bin/python`` + versioned symlinks (``python3``, ``python3.X`` …).

    Returns the ``bin/python`` File for launcher consumption.
    """
    bin_python = ctx.actions.declare_symlink("{}/bin/python".format(venv_name))
    ctx.actions.symlink(output = bin_python, target_path = tc.bin_python_target_path)
    declared.append(bin_python)

    for name in tc.versioned_python_names:
        sym = ctx.actions.declare_symlink("{}/bin/{}".format(venv_name, name))
        ctx.actions.symlink(output = sym, target_path = "python")
        declared.append(sym)

    return bin_python

def _declare_activate(ctx, default_env, venv_activate_tmpl, venv_name, declared):
    """Expand the ``bin/activate`` template with env exports and unsets."""
    out = ctx.actions.declare_file("{}/bin/activate".format(venv_name))
    exports = "\n".join(_dict_to_exports(default_env)).strip()
    unsets = "\n".join(["    unset {}".format(k) for k in default_env.keys()])
    ctx.actions.expand_template(
        template = venv_activate_tmpl,
        output = out,
        substitutions = {"{{ENVVARS}}": exports, "{{ENVVARS_UNSET}}": unsets},
        is_executable = True,
    )
    declared.append(out)

def _declare_virtualenv_shim(ctx, site_packages_rel, virtualenv_shim_py, declared):
    """Materialise ``_virtualenv.py`` + ``_virtualenv.pth`` in site-packages.

    Uses ``expand_template`` with empty substitutions (verbatim copy)
    so the shim is a real file, not a symlink into the source tree —
    ``os.path.realpath`` resolves inside the venv for tar/OCI consumers.
    """
    shim_py = ctx.actions.declare_file("{}/_virtualenv.py".format(site_packages_rel))
    ctx.actions.expand_template(
        template = virtualenv_shim_py,
        output = shim_py,
        substitutions = {},
    )
    declared.append(shim_py)

    shim_pth = ctx.actions.declare_file("{}/_virtualenv.pth".format(site_packages_rel))
    ctx.actions.write(output = shim_pth, content = "import _virtualenv\n")
    declared.append(shim_pth)

def _declare_console_scripts(ctx, console_scripts_map, console_script_tmpl, venv_name, declared):
    """Expand one shell wrapper per wheel-declared entry point."""
    for name, target in console_scripts_map.items():
        script = ctx.actions.declare_file("{}/bin/{}".format(venv_name, name))
        ctx.actions.expand_template(
            template = console_script_tmpl,
            output = script,
            substitutions = {
                "{{name}}": name,
                "{{module}}": target.module,
                "{{func}}": target.func,
            },
            is_executable = True,
        )
        declared.append(script)

def assemble_venv(
        ctx,
        *,
        safe_name,
        py_toolchain,
        imports_depset,
        is_windows,
        package_collisions,
        include_system_site_packages,
        include_user_site_packages,
        default_env,
        venv_activate_tmpl,
        virtualenv_shim_py,
        site_merge_script_py,
        console_script_tmpl,
        venv_name):
    """Declare every file + symlink that makes up a venv for a target.

    Args:
      ctx: The rule context.
      safe_name: Directory-name-safe stem for the venv dir.
      py_toolchain: Resolved Python toolchain struct from py_semantics.
      imports_depset: Depset of import paths (from
        ``py_library_utils.make_imports_depset``).
      is_windows: Whether the venv targets Windows.
      package_collisions: ``"error"`` / ``"warning"`` / ``"ignore"``.
      include_system_site_packages: Value for pyvenv.cfg's key.
      include_user_site_packages: Value for the Aspect extension key.
      default_env: Env-var dict for the activate script.
      venv_activate_tmpl: File — activate template.
      virtualenv_shim_py: File — ``_virtualenv.py`` source.
      site_merge_script_py: File — ``site_merge.py`` tool.
      console_script_tmpl: File — console-script template.
      venv_name: The venv dir basename (e.g. ``.<safe_name>``).

    Returns:
      struct with ``bin_python`` (File) and ``all_files`` (list[File]).
    """
    tc = resolve_venv_toolchain(
        ctx,
        py_toolchain = py_toolchain,
        is_windows = is_windows,
        venv_name = venv_name,
    )

    wheels = _py_library.make_wheels_depset(ctx).to_list()
    top_level_to_site_pkgs, fully_covered, console_scripts_map, merge_groups = \
        resolve_wheel_collisions(ctx, wheels, package_collisions)

    tree_by_sp, known_layout = _build_wheel_lookups(wheels)
    declared = []

    _declare_toplevel_symlinks(ctx, top_level_to_site_pkgs, tc, declared)

    if merge_groups:
        exec_toolchain = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
        exec_runtime = exec_toolchain.exec_tools.exec_runtime if exec_toolchain else None
        if exec_runtime == None:
            fail(("{}: wheels {} all contribute to the regular package `{}` — merging it " +
                  "requires an exec-configuration Python interpreter, but no `{}` toolchain " +
                  "was registered.").format(
                ctx.label,
                merge_groups[0].site_packages_list,
                merge_groups[0].root,
                EXEC_TOOLS_TOOLCHAIN,
            ))
        _run_site_merges(
            ctx,
            merge_groups,
            tree_by_sp,
            tc,
            site_merge_script_py,
            package_collisions,
            exec_runtime,
            declared,
        )

    format_imp = _make_pth_formatter(
        fully_covered,
        known_layout,
        tc.escape,
        tc.venv_to_runfiles_escape,
    )
    _declare_pth_file(ctx, imports_depset, format_imp, tc, safe_name, declared)

    _declare_pyvenv_cfg(
        ctx,
        tc,
        py_toolchain,
        venv_name,
        include_system_site_packages,
        include_user_site_packages,
        declared,
    )

    bin_python = _declare_python_bin(ctx, tc, venv_name, declared)

    _declare_activate(ctx, default_env, venv_activate_tmpl, venv_name, declared)
    _declare_virtualenv_shim(ctx, tc.site_packages_rel, virtualenv_shim_py, declared)
    _declare_console_scripts(ctx, console_scripts_map, console_script_tmpl, venv_name, declared)

    return struct(
        bin_python = bin_python,
        all_files = declared,
    )
