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
        <ns_pkg>/<entry>                        disjoint downloaded namespace
                                                portions as nested symlinks, or
        <ns_pkg>                                full merged PEP 420 top-level
        <dist>-<ver>.dist-info                  symlink to a wheel's dist-info

The whole tree is declared at analysis time as individual
`ctx.actions.declare_file` / `ctx.actions.declare_symlink` outputs so
Bazel's action cache treats each piece independently (no tree-artifact
+ remote-exec materialisation surprises).
"""

load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN")

# Template for console-script wrappers under <venv>/bin/<name>. A tiny shell
# script that execs the venv's own bin/python with an inline `-c` to import
# the entry point and call it. Keeping this as pure sh (no polyglot) sidesteps
# tokenisation quirks with `$` in strings, and the inline Python is short
# enough that not having a real `__file__` doesn't matter in practice.
# `"$@"` preserves the original argv, while sys.argv[0] is patched so the
# called function sees the script's own name. Entry-point object references
# may contain dotted attributes:
# https://packaging.python.org/en/latest/specifications/entry-points/#data-model
_CONSOLE_SCRIPT_TEMPLATE = """\
#!/bin/sh
exec "$(dirname "$0")/python" -c 'import sys; from importlib import import_module; from operator import attrgetter; sys.argv[0] = "{name}"; sys.exit(attrgetter("{func}")(import_module("{module}"))())' "$@"
"""

def _dict_to_exports(env):
    return ["export %s=\"%s\"" % (k, v) for (k, v) in env.items()]

def _resolve_wheel_collisions(ctx, wheels, package_collisions):
    """Walk PyWheelsInfo.wheels and produce merge plans for site-packages + bin/.

    Ordinary top-levels are atomic: permissive resolution projects the last
    distinct claimant in wheel postorder and suppresses every loser. For a
    shared PEP 420 directory top-level, complete pairwise-disjoint downloaded
    entry metadata is projected with nested symlinks. Incomplete or overlapping
    topology is merged as a complete top-level in postorder.

    Every top-level of a known-layout wheel is accounted for as projected,
    merged, or deliberately suppressed before that wheel is omitted from the
    `.pth` fallback. Unknown layouts remain `.pth`-backed.
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
    tl_claimants = {}
    cs_claimants = {}  # name -> list of struct(site_packages, module, func)
    for w in wheels:
        ns_set = {tl: True for tl in getattr(w, "namespace_top_levels", ())}
        directory_set = {tl: True for tl in w.directory_top_levels}
        namespace_entries_by_tl = {}
        for entry in getattr(w, "namespace_entries", ()):
            namespace_entries_by_tl.setdefault(entry.split("/")[0], []).append(entry)
        for tl in w.top_levels:
            tl_claimants.setdefault(tl, []).append(struct(
                site_packages = w.site_packages_rfpath,
                is_directory = tl in directory_set,
                is_namespace = tl in ns_set,
                install_tree = getattr(w, "install_tree", None),
                namespace_entries = tuple(namespace_entries_by_tl.get(tl, ())),
                namespace_entries_known = getattr(w, "namespace_entries_known", False),
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

    # Pass 2: resolve each complete top-level ownership unit.
    top_level_to_site_pkgs = {}
    accounted_per_wheel = {}
    merge_groups = []
    for tl, claimants in tl_claimants.items():
        distinct_claimants = []
        seen = {}
        for c in claimants:
            if c.site_packages in seen:
                continue
            seen[c.site_packages] = True
            distinct_claimants.append(c)

        for c in distinct_claimants:
            accounted_per_wheel.setdefault(c.site_packages, {})[tl] = True

        if len(distinct_claimants) == 1:
            top_level_to_site_pkgs[tl] = distinct_claimants[0].site_packages
            continue

        all_namespace = all([
            c.is_directory and c.is_namespace
            for c in distinct_claimants
        ])
        if all_namespace:
            namespace_entries = sorted([
                (entry, c.site_packages)
                for c in distinct_claimants
                for entry in c.namespace_entries
            ])

            overlap = None
            if all([c.namespace_entries_known for c in distinct_claimants]):
                entry_paths = {}
                for path, _ in namespace_entries:
                    if path in entry_paths:
                        overlap = (path, path)
                        break
                    entry_paths[path] = True

                if overlap == None:
                    for path, _ in namespace_entries:
                        segments = path.split("/")
                        for depth in range(1, len(segments)):
                            ancestor = "/".join(segments[:depth])
                            if ancestor in entry_paths:
                                overlap = (ancestor, path)
                                break
                        if overlap != None:
                            break

                if overlap == None:
                    for path, site_packages in namespace_entries:
                        top_level_to_site_pkgs[path] = site_packages
                    continue

            if overlap != None:
                merge_reason = "namespace entries `{}` and `{}` overlap".format(
                    overlap[0],
                    overlap[1],
                )
            else:
                incomplete = [
                    c.site_packages
                    for c in distinct_claimants
                    if not c.namespace_entries_known
                ]
                merge_reason = "claimants {} lack complete namespace entry metadata".format(incomplete)

            missing_trees = [
                c.site_packages
                for c in distinct_claimants
                if c.install_tree == None
            ]
            if missing_trees:
                fail(("{}: PEP 420 top-level `{}` requires a full merge because {}, " +
                      "but claimants {} have no install_tree.").format(
                    ctx.label,
                    tl,
                    merge_reason,
                    missing_trees,
                ))

            merge_groups.append(struct(
                root = tl,
                site_packages_list = [c.site_packages for c in distinct_claimants],
            ))
            if package_collisions == "warning":
                # Namespace-internal conflicts are diagnosed by PySiteMerge.
                # This generic analysis warning makes the merge itself visible
                # even when the build action finds no internal conflict.
                # buildifier: disable=print
                print("Package namespace merge in {}: PEP 420 top-level `{}` is provided by {}.".format(
                    ctx.label,
                    tl,
                    [c.site_packages for c in distinct_claimants],
                ))
            continue

        winner = distinct_claimants[0]
        for c in distinct_claimants[1:]:
            _complain("top-level", tl, winner.site_packages, c.site_packages)
            winner = c
        top_level_to_site_pkgs[tl] = winner.site_packages

    # Pass 2b: console scripts.
    console_scripts_map = {}
    for name, claimants in cs_claimants.items():
        distinct_sp = {c.site_packages: c for c in claimants}
        if len(distinct_sp) == 1:
            c = claimants[0]
            console_scripts_map[name] = struct(module = c.module, func = c.func)
            continue
        winner = claimants[0]
        seen = {winner.site_packages: True}
        for c in claimants[1:]:
            if c.site_packages in seen:
                continue
            _complain("console script", name, winner.site_packages, c.site_packages)
            winner = c
            seen[c.site_packages] = True
        console_scripts_map[name] = struct(module = winner.module, func = winner.func)

    # Pass 3: only omit a known-layout wheel from .pth after every declared
    # top-level was projected, merged, or deliberately suppressed.
    fully_covered = {}
    for w in wheels:
        if not w.layout_known:
            continue
        accounted = accounted_per_wheel.get(w.site_packages_rfpath, {})
        if all([tl in accounted for tl in w.top_levels]):
            fully_covered[w.site_packages_rfpath] = True

    return top_level_to_site_pkgs, fully_covered, console_scripts_map, merge_groups

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
        site_merge_script_py = None,
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
      site_merge_script_py: File — the site_merge.py tool source
        (usually `ctx.file._site_merge_script`). Only needed when multiple
        wheels contribute to one PEP 420 top-level; the merge action also
        requires the rule to declare the (optional) EXEC_TOOLS_TOOLCHAIN for
        an exec-configuration interpreter.
      venv_name: Optional str — explicit venv dir basename. Defaults to
        "." + safe_name + ".venv" when unset.

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
    top_level_to_site_pkgs, fully_covered_site_pkgs, console_scripts_map, merge_groups = _resolve_wheel_collisions(
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
    # a sibling py_venv target at `:<name>.venv` (auto-emitted when
    # `expose_venv = True` is set): the sibling's launcher file lands
    # at `bazel-bin/<pkg>/<name>.venv`, while any internal venv tree
    # lives under `bazel-bin/<pkg>/.<name>.venv/`. Different
    # filesystem paths, no collision. Callers can override via the
    # `venv_name` parameter.
    if venv_name == None:
        venv_name = ".{}.venv".format(safe_name)
    site_packages_rel = "{}/lib/{}/site-packages".format(venv_name, venv_py_ver)

    # site_packages_rfpath → install_tree, used only by full namespace merge
    # actions below. Direct symlinks and .pth lines locate
    # each wheel by its runfiles path directly, not through this map.
    wheels_with_trees = [w for w in wheels if getattr(w, "install_tree", None) != None]
    tree_by_sp = {w.site_packages_rfpath: w.install_tree for w in wheels_with_trees}
    known_layout_site_pkgs = {
        w.site_packages_rfpath: True
        for w in wheels
        if w.layout_known
    }

    declared = []  # accumulator for all outputs

    # Per-top-level or namespace-entry site-packages symlink: a relative symlink escaping from
    # site-packages up to the runfiles root, then down into the owning
    # wheel's `site_packages_rfpath`/<tl>. Works for both install_tree and
    # rules_python pip wheels (both stage content at their rfpath). Nested
    # namespace entries need one extra `..` for each path separator.
    for tl, wheel_site_pkgs in top_level_to_site_pkgs.items():
        out = ctx.actions.declare_symlink("{}/{}".format(site_packages_rel, tl))
        extra_up = "../" * tl.count("/")
        ctx.actions.symlink(
            output = out,
            target_path = "{}{}/{}/{}".format(extra_up, escape, wheel_site_pkgs, tl),
        )
        declared.append(out)

    # Complete PEP 420 top-level merges. Each group's directory is copied from
    # every claimant into one real directory, matching a flat installation.
    #
    # The merge runs as a build action under the exec-configuration
    # interpreter (same shape as WhlInstall's unpack action). The resolver
    # already proved every full-merge claimant has an install tree.
    for group in merge_groups:
        if site_merge_script_py == None:
            fail(("{}: wheels {} all contribute to the PEP 420 top-level `{}` — merging it " +
                  "requires the venv rule to supply the site_merge tool.").format(
                ctx.label,
                group.site_packages_list,
                group.root,
            ))
        exec_toolchain = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
        exec_runtime = exec_toolchain.exec_tools.exec_runtime if exec_toolchain else None
        if exec_runtime == None:
            fail(("{}: wheels {} all contribute to the PEP 420 top-level `{}` — merging it " +
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
            tree = tree_by_sp.get(sp)
            if tree == None:
                fail("{}: wheel at {} contributes to merged top-level `{}` but has no install_tree.".format(
                    ctx.label,
                    sp,
                    group.root,
                ))
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

    # Complete layouts have every top-level projected, merged, or deliberately
    # suppressed, so their wheel roots must not remain on .pth and resurrect an
    # atomic loser. Unknown layouts still need `site.addsitedir` so wheel-root
    # .pth shims execute.
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
    # known_layout_site_pkgs so we don't have to materialise imports_depset via
    # .to_list().
    pth_lines.add_all(imports_depset, map_each = _format_imp, allow_closure = True)

    site_packages_pth_file = ctx.actions.declare_file(
        "{}/{}.pth".format(site_packages_rel, safe_name),
    )
    ctx.actions.write(
        output = site_packages_pth_file,
        content = pth_lines,
    )
    declared.append(site_packages_pth_file)

    # pyvenv.cfg. `home` must name the BASE interpreter's bin/ — never the
    # venv's own bin/ (./bin), or CPython is left chasing the venv's python
    # symlinks and can fall back to the compile-time prefix (PBS: /install) →
    # ModuleNotFoundError: 'encodings'. Hermetic interpreters: point directly
    # at the PBS bin/, since 3.11/3.12's getpath.py resolvedpath() fails on
    # multi-hop relative symlinks across repo boundaries. System interpreters
    # (py_runtime(interpreter_path)): the dirname of the absolute interpreter
    # path — the same value `python -m venv` writes.
    if py_toolchain.runfiles_interpreter:
        pbs_rlocation = to_rlocation_path(ctx, py_toolchain.python)
        pbs_bin_dir = "/".join(pbs_rlocation.split("/")[:-1])
        pyvenv_home = "{}/{}".format(venv_to_runfiles_escape, pbs_bin_dir)
    else:
        pyvenv_home = py_toolchain.python.path.rsplit("/", 1)[0]

    pyvenv_cfg = ctx.actions.declare_file("{}/pyvenv.cfg".format(venv_name))
    ctx.actions.write(
        output = pyvenv_cfg,
        content = ("home = {home}\n" +
                   "implementation = CPython\n" +
                   "version_info = {major}.{minor}.{micro}\n" +
                   "include-system-site-packages = {include_system}\n" +
                   "aspect-include-user-site-packages = {include_user}\n" +
                   "relocatable = true\n").format(
            home = pyvenv_home,
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
