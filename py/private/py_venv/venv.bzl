"""Build-time assembly of a Python virtualenv via ctx.actions.symlink + write.

This module is the single place in rules_py that declares the files making
up a Python venv. Both `py_binary` / `py_test` (each with its own internal
venv, unless `expose_venv = True` routes them to a sibling py_venv) and
the standalone `py_venv` rule call `assemble_venv` to keep their layouts
bit-identical.

The venv shape mirrors what CPython's `python -m venv` + pip install
produces, so downstream tools (IDEs, `$VIRTUAL_ENV`-aware shells,
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
        <ns_pkg>/<entry>                        merged PEP 420 namespace: real
                                                <ns_pkg>/ dir, per-entry symlinks
                                                into each contributing wheel
        <dist>-<ver>.dist-info                  symlink when the wheel needs no
                                                whole-wheel fallback

The whole tree is declared at analysis time as individual
`ctx.actions.declare_file` / `ctx.actions.declare_symlink` outputs (no
tree-artifact + remote-exec materialisation surprises). Private venvs can
materialize projected site-packages symlinks in one action on POSIX executors.
"""

load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "VENV_SYMLINK_TOOLCHAIN")
load(":toolchains_resolver.bzl", "resolve_venv_toolchain")
load(":virtuals_resolvers.bzl", "enforce_collision_policy", "resolve_wheel_collisions")

def _dict_to_exports(env):
    return ["export %s=\"%s\"" % (k, v) for (k, v) in env.items()]

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
        venv_symlink_tool,
        console_script_tmpl,
        venv_name):
    """Declare every file + symlink that makes up a venv for a target.

    Args:
      ctx: The rule context.
      safe_name: Directory-name-safe stem for the venv dir. Slashes in the
        target name should be replaced by the caller (e.g. "_").
      py_toolchain: Resolved Python toolchain struct from py_semantics.
      imports_depset: Depset of first-party + transitive wheel import
        paths (as returned by py_library_utils.make_imports_depset).
      is_windows: Bool — whether the venv targets Windows.
      package_collisions: "error" / "warning" / "ignore" — policy applied
        when two wheels claim the same top-level (non-namespace case),
        distribution metadata entry, or console-script name.
      include_system_site_packages: Value for pyvenv.cfg's
        `include-system-site-packages` key.
      include_user_site_packages: Value for the Aspect extension
        `aspect-include-user-site-packages` key.
      default_env: Dict of env-var name → value. Exported at the top of
        the generated activate script and unset in `deactivate`.
      venv_activate_tmpl: File — the activate-script template (usually
        `ctx.file._venv_activate_tmpl`).
      virtualenv_shim_py: File — the `_virtualenv.py` distutils shim
        source (usually `ctx.file._virtualenv_shim`).
      site_merge_script_py: File — the site_merge.py tool source
        (usually `ctx.file._site_merge_script`). Only needed when the
        wheel graph contains a regular package needing a physical merge; the
        merge action also requires the rule to declare the (optional)
        EXEC_TOOLS_TOOLCHAIN for an exec-configuration interpreter.
      venv_symlink_tool: Optional FilesToRunProvider — materializes projected
        site-packages symlinks in one action for private venvs.
      console_script_tmpl: File — the console-script wrapper template
        (usually `ctx.file._console_script_tmpl`).
      venv_name: str — the venv dir basename (e.g. "." + safe_name).

    Returns:
      struct with:
        bin_python: File — the venv's bin/python symlink, for launchers
            to rlocation-resolve and exec.
        all_files: list[File] — every declared output, ready for runfiles
            / DefaultInfo aggregation.
    """

    wheels_depset = _py_library.make_wheels_depset(ctx)
    wheels = wheels_depset.to_list()
    top_level_to_site_pkgs, fully_covered_site_pkgs, console_scripts_map, merge_groups, collisions = resolve_wheel_collisions(ctx, wheels)
    enforce_collision_policy(collisions, package_collisions)

    # All toolchain-derived path/flag math (runfiles escape arithmetic,
    # wheel/venv lib-dir names, pyvenv.cfg home, versioned python names,
    # bin/python target_path) is concentrated in resolve_venv_toolchain.
    tc = resolve_venv_toolchain(
        ctx,
        py_toolchain = py_toolchain,
        is_windows = is_windows,
        venv_name = venv_name,
    )
    escape = tc.escape
    venv_to_runfiles_escape = tc.venv_to_runfiles_escape
    wheel_py_ver = tc.wheel_py_ver
    site_packages_rel = tc.site_packages_rel

    # site_packages_rfpath → install_tree, used only by the regular-package
    # merge action below. The per-top-level symlinks and .pth lines locate
    # each wheel by its runfiles path directly, not through this map.
    tree_by_sp = {w.site_packages_rfpath: w.install_tree for w in wheels}

    # site_packages_rfpath → True for wheels whose top-level layout is known
    # (they declare `top_levels`), so the per-top-level symlink loop projects
    # their root entries — including any root `.pth` files — into the venv
    # site-packages. Wheels that carry only `console_scripts` (e.g. source-built
    # scripts) leave `top_levels` empty: nothing is projected for them, so their
    # `.pth` line must use `site.addsitedir` (see `_format_imp`).
    known_layout_site_pkgs = {w.site_packages_rfpath: True for w in wheels if w.top_levels}

    declared = []  # accumulator for all outputs

    # Per-top-level site-packages symlink: a relative symlink escaping from
    # site-packages up to the runfiles root, then down into the owning
    # wheel's `site_packages_rfpath`/<tl>. Works for both install_tree and
    # rules_python pip wheels (both stage content at their rfpath).
    # `/`-joined top-levels (merged namespace packages, e.g.
    # `jaraco/functools`) need one extra `..` per segment.
    # This loop runs per (binary x top-level); build the target paths from
    # a cached per-wheel prefix rather than formatting every component.
    site_packages_prefix = site_packages_rel + "/"
    target_prefix_by_sp = {}
    symlink_outputs = []
    if venv_symlink_tool:
        symlink_arguments = ctx.actions.args()
        symlink_arguments.use_param_file("%s", use_always = True)
        symlink_arguments.set_param_file_format("multiline")
    for tl, wheel_site_pkgs in top_level_to_site_pkgs.items():
        out = ctx.actions.declare_symlink(site_packages_prefix + tl)
        target_prefix = target_prefix_by_sp.get(wheel_site_pkgs)
        if target_prefix == None:
            target_prefix = escape + "/" + wheel_site_pkgs + "/"
            target_prefix_by_sp[wheel_site_pkgs] = target_prefix
        target_path = target_prefix + tl
        if "/" in tl:
            target_path = "../" * tl.count("/") + target_path
        if venv_symlink_tool:
            symlink_arguments.add(out.path)
            symlink_arguments.add(target_path)
            symlink_outputs.append(out)
        else:
            ctx.actions.symlink(
                output = out,
                target_path = target_path,
            )
        declared.append(out)

    if symlink_outputs:
        ctx.actions.run(
            mnemonic = "PyVenvSymlinks",
            executable = venv_symlink_tool.executable,
            toolchain = VENV_SYMLINK_TOOLCHAIN,
            arguments = [symlink_arguments],
            tools = [venv_symlink_tool],
            outputs = symlink_outputs,
        )

    # Physical merges for regular packages that span wheels or collide at the
    # top level (see
    # resolve_wheel_collisions). Each group's subtree is copied from
    # every contributing wheel into a real directory inside our
    # site-packages — the layout a flat `pip install` produces. The
    # venv's own site-packages precedes the per-wheel `.pth` entries on
    # sys.path, so the merged copy is the one Python binds the regular
    # package's `__path__` to; the per-wheel originals are shadowed.
    #
    # The merge runs as a build action under the exec-configuration
    # interpreter (same shape as WhlInstall's unpack action). Every
    # PyWheelsInfo record carries an install_tree (see providers.bzl),
    # so each contributing wheel resolves in tree_by_sp.
    for group in merge_groups:
        exec_toolchain = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
        exec_runtime = exec_toolchain.exec_tools.exec_runtime if exec_toolchain else None
        if exec_runtime == None:
            fail(("{}: wheels {} all contribute to the regular package `{}` — merging it " +
                  "requires an exec-configuration Python interpreter, but no `{}` toolchain " +
                  "was registered.").format(
                ctx.label,
                group.site_packages_list,
                group.root,
                EXEC_TOOLS_TOOLCHAIN,
            ))

        merged_dir = ctx.actions.declare_directory(
            "{}/{}".format(site_packages_rel, group.root),
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
                format_each = "%s/lib/{}/site-packages/{}".format(wheel_py_ver, group.root),
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
            execution_requirements = {
                "supports-path-mapping": "1",
            },
        )
        declared.append(merged_dir)

    # A wheel-root `.pth` shim only fires when its file sits in the venv's own
    # site-packages. Wheels that declare `top_levels` (known layout) had their
    # root entries — including any root `.pth` files — projected there by the
    # per-top-level symlink loop above, so they emit a plain path line;
    # `site.addsitedir` would re-scan the wheel root and run the shim a second
    # time. Wheels with no projected layout (console-script-only, e.g.
    # source-built scripts, or metadata-free `py_unpacked_wheel`s) fall back to
    # `site.addsitedir` so their site-packages joins sys.path and root `.pth`
    # shims run at all; the path is sys.prefix-relative to survive RBE sandbox
    # layouts.
    def _format_imp(imp):
        if imp in fully_covered_site_pkgs:
            return None
        if imp.endswith("site-packages") and imp not in known_layout_site_pkgs:
            return ("import os, sys, site; " +
                    "site.addsitedir(os.path.normpath(os.path.join(" +
                    "sys.prefix, \"{venv_escape}\", \"{imp}\")))").format(
                venv_escape = venv_to_runfiles_escape,
                imp = imp,
            )
        return "{}/{}".format(escape, imp)

    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")
    pth_lines.add(escape)

    # allow_closure lets _format_imp capture fully_covered_site_pkgs /
    # known_layout_site_pkgs so we don't have to materialise imports_depset
    # via .to_list().
    pth_lines.add_all(imports_depset, map_each = _format_imp, allow_closure = True)

    site_packages_pth_file = ctx.actions.declare_file(
        "{}/{}.pth".format(site_packages_rel, safe_name),
    )
    ctx.actions.write(
        output = site_packages_pth_file,
        content = pth_lines,
    )
    declared.append(site_packages_pth_file)

    pyvenv_cfg = ctx.actions.declare_file("{}/pyvenv.cfg".format(venv_name))
    home_line = "home =\n" if tc.pyvenv_home == "" else "home = {}\n".format(tc.pyvenv_home)
    ctx.actions.write(
        output = pyvenv_cfg,
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
            include_system = str(include_system_site_packages).lower(),
            include_user = str(include_user_site_packages).lower(),
        ),
    )
    declared.append(pyvenv_cfg)

    # bin/python — unresolved symlink (declare_symlink + target_path)
    # rather than declare_file + target_file: target_file lets Bazel pick
    # relative vs absolute per version (Bazel 8 rel, Bazel 9 abs), and an
    # absolute target bakes in the build-host execroot path that does not
    # exist inside an OCI container, leaving a dangling symlink. The
    # target path itself is computed by resolve_venv_toolchain.
    bin_python = ctx.actions.declare_symlink("{}/bin/python".format(venv_name))
    ctx.actions.symlink(
        output = bin_python,
        target_path = tc.bin_python_target_path,
    )
    declared.append(bin_python)

    # Versioned python symlinks (python3, python3.<MAJ>.<MIN>, and
    # python3.<MAJ>.<MIN>t for freethreaded) all point at the sibling
    # `python`; names resolved by resolve_venv_toolchain.
    for versioned_name in tc.versioned_python_names:
        sym = ctx.actions.declare_symlink("{}/bin/{}".format(venv_name, versioned_name))
        ctx.actions.symlink(
            output = sym,
            target_path = "python",
        )
        declared.append(sym)

    # bin/activate
    bin_activate = ctx.actions.declare_file("{}/bin/activate".format(venv_name))
    envvar_exports = "\n".join(_dict_to_exports(default_env)).strip()
    envvar_unsets = "\n".join(
        ["    unset {}".format(k) for k in default_env.keys()],
    )
    ctx.actions.expand_template(
        template = venv_activate_tmpl,
        output = bin_activate,
        substitutions = {
            "{{ENVVARS}}": envvar_exports,
            "{{ENVVARS_UNSET}}": envvar_unsets,
        },
        is_executable = True,
    )
    declared.append(bin_activate)

    # _virtualenv.py + _virtualenv.pth — distutils shim for pip interop.
    # Materialised as a real file, not a symlink into the rules_py source
    # tree, so tar/OCI/rsync etc. consumers of the venv can resolve the file.
    virtualenv_shim_py_out = ctx.actions.declare_file(
        "{}/_virtualenv.py".format(site_packages_rel),
    )
    ctx.actions.expand_template(
        template = virtualenv_shim_py,
        output = virtualenv_shim_py_out,
        substitutions = {},
    )
    declared.append(virtualenv_shim_py_out)

    virtualenv_shim_pth = ctx.actions.declare_file(
        "{}/_virtualenv.pth".format(site_packages_rel),
    )
    ctx.actions.write(
        output = virtualenv_shim_pth,
        content = "import _virtualenv\n",
    )
    declared.append(virtualenv_shim_pth)

    # Console-script wrappers under <venv>/bin/<name>.
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

    return struct(
        bin_python = bin_python,
        all_files = declared,
    )
