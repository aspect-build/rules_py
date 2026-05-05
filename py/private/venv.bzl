"""Build-time assembly of a Python virtualenv via ctx.actions.symlink + write.

This module is the single place in rules_py that declares the files making
up a Python venv. Both `py_binary` / `py_test` (each with its own internal
venv, when `external_venv` is unset) and the standalone `py_venv` rule call
`assemble_venv` to keep their layouts bit-identical.

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
        <dist>-<ver>.dist-info                  symlink to a wheel's dist-info

The whole tree is declared at analysis time as individual
`ctx.actions.declare_file` / `ctx.actions.declare_symlink` outputs so
Bazel's action cache treats each piece independently (no tree-artifact
+ remote-exec materialisation surprises).
"""

load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")

# Template for console-script wrappers under <venv>/bin/<name>. A tiny shell
# script that execs the venv's own bin/python with an inline `-c` to import
# the entry point and call it. Keeping this as pure sh (no polyglot) sidesteps
# tokenisation quirks with `$` in strings, and the inline Python is short
# enough that not having a real `__file__` doesn't matter in practice.
# `"$@"` preserves the original argv, while sys.argv[0] is patched so the
# called function sees the script's own name.
_CONSOLE_SCRIPT_TEMPLATE = """\
#!/bin/sh
exec "$(dirname "$0")/python" -c 'import sys; from {module} import {func}; sys.argv[0] = "{name}"; sys.exit({func}())' "$@"
"""

def _dict_to_exports(env):
    return ["export %s=\"%s\"" % (k, v) for (k, v) in env.items()]

def _resolve_wheel_collisions(ctx, wheels, package_collisions):
    """Walk PyWheelsInfo.wheels and produce merge plans for site-packages + bin/.

    Two kinds of collision get checked:

    * **Top-level in site-packages.** Multiple wheels claiming the same
      top-level name. When ALL contributing wheels flag the name as a
      PEP 420 namespace package (no `__init__.py` at that level), the
      collision is benign — skip the per-top-level symlink and let each
      wheel's site-packages fall through to `.pth` + `addsitedir`, where
      Python's namespace machinery merges contributions natively.
      Otherwise apply `package_collisions` policy.

    * **Console-script name in bin/.** Apply `package_collisions` directly
      — no namespace equivalent.

    Returns:
      top_level_to_site_pkgs: dict {top_level_name: site_packages_rfpath}
      fully_covered_site_pkgs: dict[str, True] — site-packages paths whose
          declared top-levels ALL ended up claimed by them — safe to drop
          from the .pth fallback.
      console_scripts_map: dict {script_name: struct(module, func)} after
          collision resolution.
    """

    def _complain(what, name, a, b):
        msg = "Package collision in {target}: {what} `{name}` is provided by both {a} and {b}.".format(
            target = str(ctx.label),
            what = what,
            name = name,
            a = a,
            b = b,
        )
        if package_collisions == "error":
            fail(msg + "\nSet `package_collisions = \"warning\"` or \"ignore\" to downgrade.")
        elif package_collisions == "warning":
            # buildifier: disable=print
            print(msg)

    # Pass 1: bucket claimants per top-level / per console-script name.
    tl_claimants = {}  # tl -> list of struct(site_packages, is_ns)
    cs_claimants = {}  # name -> list of struct(site_packages, module, func)
    for w in wheels:
        ns_set = {tl: True for tl in getattr(w, "namespace_top_levels", ())}
        for tl in w.top_levels:
            tl_claimants.setdefault(tl, []).append(struct(
                site_packages = w.site_packages_rfpath,
                is_ns = tl in ns_set,
            ))
        for entry in getattr(w, "console_scripts", ()):
            # Entry encoding from the repo rule: "name=module:func".
            if "=" not in entry:
                continue
            name, _, target = entry.partition("=")
            if ":" not in target:
                continue
            module, _, func = target.partition(":")
            name = name.strip()
            module = module.strip()
            func = func.strip()
            if not name or not module or not func:
                continue
            cs_claimants.setdefault(name, []).append(struct(
                site_packages = w.site_packages_rfpath,
                module = module,
                func = func,
            ))

    # Pass 2: resolve top-levels. Track which (site_packages, tl) pairs
    # we SKIPPED so pass 3 can decide which wheels are fully covered.
    top_level_to_site_pkgs = {}
    skipped_per_wheel = {}
    for tl, claimants in tl_claimants.items():
        distinct_sp = {c.site_packages: c for c in claimants}
        if len(distinct_sp) == 1:
            top_level_to_site_pkgs[tl] = claimants[0].site_packages
            continue

        all_namespace = all([c.is_ns for c in claimants])
        if all_namespace:
            for c in claimants:
                skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True
            continue

        first = claimants[0]
        top_level_to_site_pkgs[tl] = first.site_packages
        seen_losers = {}
        for c in claimants[1:]:
            if c.site_packages == first.site_packages or c.site_packages in seen_losers:
                continue
            _complain("top-level", tl, first.site_packages, c.site_packages)
            seen_losers[c.site_packages] = True
            skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True

    # Pass 2b: console scripts.
    console_scripts_map = {}
    for name, claimants in cs_claimants.items():
        distinct_sp = {c.site_packages: c for c in claimants}
        if len(distinct_sp) == 1:
            c = claimants[0]
            console_scripts_map[name] = struct(module = c.module, func = c.func)
            continue
        first = claimants[0]
        console_scripts_map[name] = struct(module = first.module, func = first.func)
        seen_losers = {}
        for c in claimants[1:]:
            if c.site_packages == first.site_packages or c.site_packages in seen_losers:
                continue
            _complain("console script", name, first.site_packages, c.site_packages)
            seen_losers[c.site_packages] = True

    # Pass 3: wheels fully covered by direct symlinks.
    fully_covered = {}
    for w in wheels:
        skipped = skipped_per_wheel.get(w.site_packages_rfpath, {})
        covered = True
        for tl in w.top_levels:
            if tl in skipped or top_level_to_site_pkgs.get(tl) != w.site_packages_rfpath:
                covered = False
                break
        if covered:
            fully_covered[w.site_packages_rfpath] = True

    return top_level_to_site_pkgs, fully_covered, console_scripts_map

def assemble_venv(
        ctx,
        *,
        safe_name,
        py_toolchain,
        imports_depset,
        package_collisions = "error",
        include_system_site_packages = False,
        include_user_site_packages = False,
        default_env = {},
        venv_activate_tmpl,
        virtualenv_shim_py,
        venv_name = None):
    """Declare every file + symlink that makes up a venv for a target.

    Args:
      ctx: The rule context.
      safe_name: Directory-name-safe stem for the venv dir. Slashes in the
        target name should be replaced by the caller (e.g. "_").
      py_toolchain: Resolved Python toolchain struct from py_semantics.
      imports_depset: Depset of first-party + transitive wheel import
        paths (as returned by py_library_utils.make_imports_depset).
      package_collisions: "error" / "warning" / "ignore" — policy applied
        when two wheels claim the same top-level (non-namespace case) or
        the same console-script name.
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

    Returns:
      struct with:
        venv_name: str — the venv dir's basename (default "." + safe_name + ".venv").
        bin_python: File — the venv's bin/python symlink, for launchers
            to rlocation-resolve and exec.
        all_files: list[File] — every declared output, ready for runfiles
            / DefaultInfo aggregation.
        site_packages_pth_file: File — the main .pth (useful if the
            caller needs to know its runfiles path).
        pyvenv_cfg: File — declared pyvenv.cfg.
    """

    wheels_depset = _py_library.make_wheels_depset(ctx)
    wheels = wheels_depset.to_list()
    top_level_to_site_pkgs, fully_covered_site_pkgs, console_scripts_map = _resolve_wheel_collisions(
        ctx,
        wheels,
        package_collisions,
    )

    # Layout + escape math — the venv is a sibling of the target's
    # declared outputs at <pkg>/<venv_name>/, so from the .pth / symlinks
    # inside site-packages we need to walk up to the runfiles root before
    # descending into an external wheel repo.
    #
    # Components below the runfiles root, from the .pth's directory:
    #   1 workspace
    # + N package segments
    # + 1 venv segment
    # + 3 (lib, python<MAJ>.<MIN>, site-packages)
    # `py_ver` controls two distinct layouts that agree most of the time
    # but diverge for freethreaded interpreters:
    #
    # * `venv_py_ver` — the lib-dir name inside OUR venv. Freethreaded
    #   Python 3.13+ (and onwards) expects its site-packages at
    #   `lib/python<M>.<m>t/site-packages/`. If we put ours at
    #   `python<M>.<m>/`, the interpreter never finds our symlinks.
    # * `wheel_py_ver` — the lib-dir name inside a wheel's `install_tree`.
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
    escape_count = 1 + package_depth + 1 + 3
    escape = "/".join([".."] * escape_count)

    # From venv root (= sys.prefix at runtime) up to runfiles root.
    venv_to_runfiles_escape = "/".join([".."] * (2 + package_depth))

    # Default basename is `.{name}.venv/` — the Pythonic name that
    # IDEs auto-detect. The leading dot also keeps this distinct from
    # a sibling py_venv target at `:<name>.venv` (auto-emitted by
    # `py_binary(expose_venv = True, ...)`): the sibling's launcher
    # file lands at `bazel-bin/<pkg>/<name>.venv`, while any internal
    # venv tree lives under `bazel-bin/<pkg>/.<name>.venv/`. Different
    # filesystem paths, no collision. Callers can override via the
    # `venv_name` parameter.
    if venv_name == None:
        venv_name = ".{}.venv".format(safe_name)
    site_packages_rel = "{}/lib/{}/site-packages".format(venv_name, venv_py_ver)

    # Two-hop alias for each wheel that carries its install_tree File:
    #
    #   Hop 1: <venv>/_wheels/<alias>/  →  <install_tree>   (resolved)
    #   Hop 2: <venv>/lib/<py>/site-packages/<tl>
    #            →  ../../../_wheels/<alias>/lib/<py>/site-packages/<tl>
    #          (intra-venv relative, declare_symlink)
    #
    # Hop 1 is a `ctx.actions.symlink(output=declare_directory, target_file=<tree>)`.
    # In bazel-bin it's a single absolute symlink to the wheel's tree
    # artifact; in runfiles Bazel materialises it as a real directory with
    # per-file absolute symlinks inside — same shape the aliased tree
    # artifact already has in runfiles, so no new materialisation cost.
    #
    # Hop 2 is a `declare_symlink` with a relative `target_path`. Relative
    # depth is identical in bazel-bin and runfiles because the target
    # stays entirely within the venv's own output tree. This is what
    # unblocks `py_image_layer` (which walks bazel-bin) and any other
    # bazel-bin-walking tool.
    site_packages_to_wheels_alias = "/".join([".."] * 3) + "/_wheels"

    # Map from site_packages_rfpath → alias index (and alias-dir File)
    # for wheels that carry install_tree. Indexing by rfpath (instead of
    # label) keeps the mapping deterministic across builds.
    wheels_with_trees = [w for w in wheels if getattr(w, "install_tree", None) != None]
    wheel_alias_by_sp = {}
    for i, w in enumerate(wheels_with_trees):
        wheel_alias_by_sp[w.site_packages_rfpath] = i

    declared = []  # accumulator for all outputs

    # Hop 1: per-wheel directory aliases. Bazel picks an absolute path
    # under bazel-bin; the output is a tree artifact whose contents
    # dereference the install_tree.
    for i, w in enumerate(wheels_with_trees):
        alias_dir = ctx.actions.declare_directory(
            "{}/_wheels/{}".format(venv_name, i),
        )
        ctx.actions.symlink(
            output = alias_dir,
            target_file = w.install_tree,
        )
        declared.append(alias_dir)

    # Hop 2 (+ legacy one-hop fallback): per-top-level site-packages
    # symlinks. If the owning wheel has a `_wheels/<i>/` alias, we route
    # through it with an intra-venv relative path; otherwise fall back
    # to the historical runfiles-root-escape unresolved symlink.
    for tl, wheel_site_pkgs in top_level_to_site_pkgs.items():
        out = ctx.actions.declare_symlink("{}/{}".format(site_packages_rel, tl))
        alias_idx = wheel_alias_by_sp.get(wheel_site_pkgs)
        if alias_idx != None:
            ctx.actions.symlink(
                output = out,
                target_path = "{}/{}/lib/{}/site-packages/{}".format(
                    site_packages_to_wheels_alias,
                    alias_idx,
                    wheel_py_ver,
                    tl,
                ),
            )
        else:
            ctx.actions.symlink(
                output = out,
                target_path = "{}/{}/{}".format(escape, wheel_site_pkgs, tl),
            )
        declared.append(out)

    # .pth for anything NOT handled by the top-level symlinks:
    #   * runfiles root itself (first line) — needed by rules_python runfiles helper
    #   * first-party import dirs (workspace roots, py_library imports)
    #   * wheel site-packages dirs whose owning wheel lacks PyWheelsInfo
    #     metadata (or whose coverage is partial due to collisions) —
    #     get the `site.addsitedir(...)` treatment so wheel-internal .pth
    #     files (*-nspkg.pth, editable installs, etc.) run
    #
    # For wheels that have a `_wheels/<i>/` alias, the addsitedir target
    # goes through the alias (intra-venv, context-agnostic). For wheels
    # without it, we keep the legacy runfiles-escape form.
    pth_content_lines = [escape]
    for imp in imports_depset.to_list():
        if imp in fully_covered_site_pkgs:
            continue
        if imp.endswith("site-packages"):
            alias_idx = wheel_alias_by_sp.get(imp)
            if alias_idx != None:
                pth_content_lines.append(
                    ("import os, sys, site; " +
                     "site.addsitedir(os.path.normpath(os.path.join(" +
                     "sys.prefix, \"_wheels\", \"{idx}\", \"lib\", \"{py_ver}\", \"site-packages\")))").format(
                        idx = alias_idx,
                        py_ver = wheel_py_ver,
                    ),
                )
            else:
                pth_content_lines.append(
                    ("import os, sys, site; " +
                     "site.addsitedir(os.path.normpath(os.path.join(" +
                     "sys.prefix, \"{venv_escape}\", \"{imp}\")))").format(
                        venv_escape = venv_to_runfiles_escape,
                        imp = imp,
                    ),
                )
        else:
            pth_content_lines.append("{}/{}".format(escape, imp))

    site_packages_pth_file = ctx.actions.declare_file(
        "{}/{}.pth".format(site_packages_rel, safe_name),
    )
    ctx.actions.write(
        output = site_packages_pth_file,
        content = "\n".join(pth_content_lines) + "\n",
    )
    declared.append(site_packages_pth_file)

    # pyvenv.cfg. `home = ./bin/` points at the venv's own bin dir
    # (relative to pyvenv.cfg's location), so Python finds our bin/python
    # symlink there and follows it to locate the real interpreter and
    # derive sys.base_prefix.
    pyvenv_cfg = ctx.actions.declare_file("{}/pyvenv.cfg".format(venv_name))
    ctx.actions.write(
        output = pyvenv_cfg,
        content = ("home = ./bin/\n" +
                   "implementation = CPython\n" +
                   "version_info = {major}.{minor}.{micro}\n" +
                   "include-system-site-packages = {include_system}\n" +
                   "aspect-include-user-site-packages = {include_user}\n" +
                   "relocatable = true\n").format(
            major = py_toolchain.interpreter_version_info.major,
            minor = py_toolchain.interpreter_version_info.minor,
            micro = py_toolchain.interpreter_version_info.micro,
            include_system = str(include_system_site_packages).lower(),
            include_user = str(include_user_site_packages).lower(),
        ),
    )
    declared.append(pyvenv_cfg)

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
    # and then down through the interpreter's rlocation path — which is
    # exactly the shape `runfiles` libraries would compute. Up count:
    # 1 (bin) + 1 (venv) + package_depth + 1 (workspace) = 3 + pkg.
    # For system-interpreter (no runfiles_interpreter), fall back to the
    # absolute path — these are already non-hermetic by construction.
    bin_python = ctx.actions.declare_symlink("{}/bin/python".format(venv_name))
    if py_toolchain.runfiles_interpreter:
        bin_to_runfiles_root = "/".join([".."] * (3 + package_depth))
        ctx.actions.symlink(
            output = bin_python,
            target_path = "{}/{}".format(
                bin_to_runfiles_root,
                to_rlocation_path(ctx, py_toolchain.python),
            ),
        )
    else:
        ctx.actions.symlink(
            output = bin_python,
            target_path = py_toolchain.python.path,
        )
    declared.append(bin_python)

    # Versioned python symlinks: python3, python3.<MAJ>.<MIN>, and on
    # freethreaded interpreters also python3.<MAJ>.<MIN>t (the name the
    # interpreter looks itself up under). All point at the sibling `python`.
    versioned_names = [
        "python{}".format(py_toolchain.interpreter_version_info.major),
        "python{}.{}".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
        ),
    ]
    if py_toolchain.freethreaded:
        versioned_names.append("python{}.{}t".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
        ))
    for versioned_name in versioned_names:
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
    virtualenv_shim_py_out = ctx.actions.declare_file(
        "{}/_virtualenv.py".format(site_packages_rel),
    )
    ctx.actions.symlink(
        output = virtualenv_shim_py_out,
        target_file = virtualenv_shim_py,
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
        ctx.actions.write(
            output = script,
            content = _CONSOLE_SCRIPT_TEMPLATE.format(
                name = name,
                module = target.module,
                func = target.func,
            ),
            is_executable = True,
        )
        declared.append(script)

    return struct(
        venv_name = venv_name,
        bin_python = bin_python,
        all_files = declared,
        site_packages_pth_file = site_packages_pth_file,
        pyvenv_cfg = pyvenv_cfg,
    )
