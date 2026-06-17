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
      _merged/<package_root>/<package_root>        cross-wheel regular package
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
        <package_root>                          symlink to a wheel's file or dir,
                                                or a merged regular package
        <dist>-<ver>.dist-info                  physical venv metadata symlink

Most of the tree is declared as individual files and symlinks. Only a regular
package that spans namespace wheels becomes a TreeArtifact; duplicate regular
packages follow the configured collision policy and retain one wheel-local
winner.
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
      top-level name. When all contributing wheels flag the name as a
      PEP 420 namespace package (no `__init__.py` at that level), the
      collision is benign. Namespace portions may come from separate
      directory trees, while regular packages are self-contained:
      https://peps.python.org/pep-0420/#differences-between-namespace-packages-and-regular-packages

      Materialize a real `site-packages/<tl>/` directory whose members
      are per-entry symlinks into each contributing wheel. Runtime imports
      would also work through the `.pth` fallback because Python's
      `site` startup adds those paths to `sys.path`:
      https://docs.python.org/3/library/site.html

      Static tools inspect the concrete site-packages tree, so the
      materialized entries expose packages and `py.typed` markers without
      executing Python startup. Wheels lacking entry metadata (hand-written
      `py_unpacked_wheel`) keep the historical `.pth`-only fallback.
      Otherwise apply `package_collisions` policy.

      Within an all-namespace top-level there's one shape `.pth` +
      `addsitedir` cannot handle: a REGULAR package spanning wheels.
      E.g. azure-core owns `azure/core/` (has `__init__.py`) while
      azure-core-tracing-opentelemetry installs
      `azure/core/tracing/ext/opentelemetry_span/` into that same tree.
      Python locks a regular package's `__path__` to the first
      directory found, so the second wheel's graft is unreachable. We
      detect this by cross-referencing each wheel's `regular_roots`
      against the other claimants' `namespace_dirs` skeletons, then
      merge the complete top-level namespace from every materialized
      claimant. This produces one concrete overlay following wheel
      dependency precedence, remains visible to static tools, and gives
      Bazel one owned output instead of nested sibling outputs.

    * **Console-script name in bin/.** Apply `package_collisions` directly
      — no namespace equivalent.

    Returns:
      top_level_to_site_pkgs: dict {site_packages_relative_path: site_packages_rfpath}
          — keys are top-level names, plus `/`-joined deeper paths (e.g.
          `jaraco/functools`) for merged namespace packages.
      fully_covered_site_pkgs: dict[str, True] — site-packages paths whose
          declared top-levels ALL ended up claimed by them (directly or
          via a complete namespace merge) — safe to drop from the .pth
          fallback.
      console_scripts_map: dict {script_name: struct(module, func)} after
          collision resolution.
      merge_groups: list of struct(root, site_packages_list,
          missing_required_site_packages) — top-level namespace package
          dirs containing a regular package that spans wheels, with every
          materialized claimant's site-packages path in first-wins priority
          order and any required claimant that cannot be materialized.
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
    tl_claimants = {}  # tl -> list of struct(site_packages, is_ns, ns_entries)
    cs_claimants = {}  # name -> list of struct(site_packages, module, func)
    wheel_by_sp = {}  # site_packages_rfpath -> wheel struct
    for w in wheels:
        wheel_by_sp[w.site_packages_rfpath] = w
        ns_set = {tl: True for tl in getattr(w, "namespace_top_levels", ())}
        ns_entries_by_tl = {}
        for entry in getattr(w, "namespace_entries", ()):
            ns_entries_by_tl.setdefault(entry.split("/")[0], []).append(entry)
        for tl in w.top_levels:
            tl_claimants.setdefault(tl, []).append(struct(
                site_packages = w.site_packages_rfpath,
                is_ns = tl in ns_set,
                ns_entries = tuple(ns_entries_by_tl.get(tl, [])),
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
    # we SKIPPED (left to the .pth fallback) and which namespace claims
    # were fully COVERED by per-entry symlinks, so pass 3 can decide
    # which wheels are fully covered.
    top_level_to_site_pkgs = {}
    skipped_per_wheel = {}
    ns_covered_per_wheel = {}
    conflicted_top_levels = {}  # top-level -> merge group
    for tl, claimants in tl_claimants.items():
        distinct_sp = {c.site_packages: c for c in claimants}
        if len(distinct_sp) == 1:
            top_level_to_site_pkgs[tl] = claimants[0].site_packages
            continue

        all_namespace = all([c.is_ns for c in claimants])
        if all_namespace:
            # Deep-overlap scan first: a regular root of one claimant
            # appearing in another claimant's namespace skeleton (B
            # installs files below it) or as another's own regular root
            # marks a REGULAR package spanning wheels (azure-core +
            # azure-core-tracing-opentelemetry). Python locks a regular
            # package's __path__ to one directory, so neither .pth nor a
            # per-entry symlink can merge it — collect the roots for the
            # physical merge in pass 2a, and record every all-namespace
            # claimant sp.
            tl_prefix = tl + "/"
            required_site_packages = {}
            for sp_a in distinct_sp.keys():
                w_a = wheel_by_sp[sp_a]
                for root in getattr(w_a, "regular_roots", ()):
                    if not root.startswith(tl_prefix):
                        continue
                    for sp_b in distinct_sp.keys():
                        if sp_b == sp_a:
                            continue
                        w_b = wheel_by_sp[sp_b]
                        if (root in getattr(w_b, "namespace_dirs", ()) or
                            root in getattr(w_b, "regular_roots", ())):
                            required_site_packages[sp_a] = True
                            required_site_packages[sp_b] = True

            unique_claimants = distinct_sp.values()

            # When a regular package spans wheels under this top-level the
            # physical merge (pass 2a -> merge_groups) owns the conflicted
            # subtree and the remaining namespace portions fall through to
            # .pth. Don't ALSO lay per-entry symlinks for this top-level:
            # they'd collide with the merged directory and can't represent
            # a regular package anyway.
            if required_site_packages:
                materialized = []
                missing_required = []
                for c in unique_claimants:
                    wheel = wheel_by_sp[c.site_packages]
                    if getattr(wheel, "install_tree", None) != None:
                        materialized.append(c.site_packages)
                        ns_covered_per_wheel.setdefault(c.site_packages, {})[tl] = True
                    else:
                        skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True
                        if c.site_packages in required_site_packages:
                            missing_required.append(c.site_packages)
                conflicted_top_levels[tl] = struct(
                    missing_required_site_packages = missing_required,
                    root = tl,
                    site_packages_list = materialized,
                )
                continue

            # Pure PEP 420 namespace (no regular package spanning wheels).
            # Entry metadata is optional (a hand-written py_unpacked_wheel
            # may omit it). Merge the claimants that HAVE entries
            # concretely, and route the entryless ones to the .pth
            # fallback: a concrete `site-packages/<tl>/` directory (no
            # `__init__.py`) and a .pth/addsitedir portion both contribute
            # to the same PEP 420 namespace at runtime, so the well-formed
            # wheels stay visible to static tools (mypy, pyright) while the
            # entryless wheel still resolves at import time. Only when NO
            # claimant has entries do we keep the historical .pth-only
            # fallback for the whole group.
            entried = [c for c in unique_claimants if c.ns_entries]
            for c in unique_claimants:
                if not c.ns_entries:
                    skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True
            if not entried:
                continue

            # Per-entry merge over the entries-bearing claimants: first
            # wheel to claim an entry wins. A later distinct wheel shipping
            # the same entry is a genuine collision (same subpackage twice)
            # — complain per policy and leave the loser on the .pth path.
            # (An entryless claimant shipping the same subpackage can't be
            # detected here; the concrete symlink wins deterministically
            # over its .pth portion — the same first-on-path resolution the
            # old all-.pth path gave, only now order-independent.)
            entry_owner = {}
            for c in entried:
                for entry in c.ns_entries:
                    prior = entry_owner.get(entry)
                    if prior == None:
                        entry_owner[entry] = c
                    elif prior.site_packages != c.site_packages:
                        _complain("namespace entry", entry, prior.site_packages, c.site_packages)
                        skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True

            # A nested-namespace mismatch (wheel A ships
            # `google/cloud/__init__.py` while wheel B treats
            # `google/cloud` as a namespace and ships
            # `google/cloud/bigquery`) yields an entry that is a
            # path-prefix of another — two declared outputs at
            # conflicting paths. Keep the shallower entry (its symlink
            # subsumes the deeper region) and leave the deeper wheel on
            # the .pth path.
            #
            # KNOWN LIMITATION: this is a heuristic, not a full merge.
            # When the shallower entry is a REGULAR package (A's
            # `google/cloud/__init__.py`), `google.cloud` is not a
            # namespace at runtime, so B's `.pth`-routed
            # `google/cloud/bigquery` is shadowed and won't import — a flat
            # `pip install` would instead overlay both into one
            # `google/cloud/` directory. Correctly handling that needs a
            # recursive merge at the conflict depth (symlink A's
            # `__init__.py` + members AND B's subpackages into a concrete
            # `google/cloud/`), which in turn needs per-member metadata we
            # don't currently emit. We surface the conflict via
            # `package_collisions` rather than silently mis-merging. No
            # wheel set in our fixtures hits this (every google-* wheel
            # treats `google/cloud` as a namespace); it's defensive.
            for entry in entry_owner.keys():
                segments = entry.split("/")
                for depth in range(2, len(segments)):
                    shallower = entry_owner.get("/".join(segments[:depth]))
                    if shallower == None:
                        continue
                    loser = entry_owner.pop(entry)
                    if shallower.site_packages != loser.site_packages:
                        _complain("namespace entry", entry, shallower.site_packages, loser.site_packages)
                        skipped_per_wheel.setdefault(loser.site_packages, {})[tl] = True
                    break

            for entry, c in entry_owner.items():
                top_level_to_site_pkgs[entry] = c.site_packages

            # Entries-bearing claimants that kept every one of their
            # entries are fully represented by the merged directory; record
            # per-wheel coverage so pass 3 can drop them from the .pth
            # fallback. Entryless claimants stay in skipped_per_wheel
            # (routed to .pth above) and are intentionally excluded.
            for c in entried:
                if tl not in skipped_per_wheel.get(c.site_packages, {}):
                    ns_covered_per_wheel.setdefault(c.site_packages, {})[tl] = True
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

    # Pass 2a: one concrete output per conflicted top-level namespace. Merging
    # every claimant preserves unrelated namespace portions for static tools
    # and avoids nested outputs below an undeclared parent directory.
    merge_groups = [conflicted_top_levels[root] for root in sorted(conflicted_top_levels.keys())]

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

    # Pass 3: wheels fully covered by direct (or complete per-entry
    # namespace) symlinks.
    fully_covered = {}
    for w in wheels:
        skipped = skipped_per_wheel.get(w.site_packages_rfpath, {})
        ns_covered = ns_covered_per_wheel.get(w.site_packages_rfpath, {})
        covered = True
        for tl in w.top_levels:
            if tl in skipped:
                covered = False
                break
            if top_level_to_site_pkgs.get(tl) != w.site_packages_rfpath and tl not in ns_covered:
                covered = False
                break
        if covered:
            fully_covered[w.site_packages_rfpath] = True

    return top_level_to_site_pkgs, fully_covered, console_scripts_map, merge_groups

def _wheel_key(wheel):
    """8-hex key derived from the wheel's install_tree.short_path (globally
    unique among File objects). Same wheel → same key on every build, and
    adding/removing one wheel doesn't shift the keys of others.
    """
    h = "%x" % (hash(wheel.install_tree.short_path) & 0xFFFFFFFF)
    return "0" * (8 - len(h)) + h

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
        runfiles_imports_py,
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
      runfiles_imports_py: File — site startup helper that resolves first-party
        modules from a runfiles manifest when no directory tree exists.
      venv_activate_tmpl: File — the activate-script template (usually
        `ctx.file._venv_activate_tmpl`).
      virtualenv_shim_py: File — the `_virtualenv.py` distutils shim
        source (usually `ctx.file._virtualenv_shim`).
      site_merge_script_py: File — the site_merge.py tool source
        (usually `ctx.file._site_merge_script`). Only needed when a regular
        package spans wheels; the merge action also requires the rule to
        declare the (optional) EXEC_TOOLS_TOOLCHAIN for an exec-configuration
        interpreter.
      venv_name: Optional str — explicit venv dir basename. Defaults to
        "." + safe_name + ".venv" when unset.

    Returns:
      struct with:
        venv_name: str — the venv dir's basename (default "." + safe_name + ".venv").
        bin_python: File — the venv's bin/python symlink, for launchers
            to rlocation-resolve and exec.
        all_files: list[File] — every declared output, ready for runfiles
            / DefaultInfo aggregation.
        dependency_files: list[File] — generated third-party overlays that
            packaging rules must keep out of first-party source layers.
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

    # Two-hop indirection for each wheel that carries its install_tree File:
    #
    #   Hop 1: <venv>/_wheels/<key>/  →  <install_tree>   (resolved)
    #   Hop 2: <venv>/lib/<py>/site-packages/<tl>
    #            →  ../../../_wheels/<key>/lib/<py>/site-packages/<tl>
    #          (intra-venv relative, declare_symlink)
    #
    # Hop 1 is a `ctx.actions.symlink(output=declare_directory, target_file=<tree>)`.
    # In bazel-bin it's a single absolute symlink to the wheel's tree
    # artifact; in runfiles Bazel materialises it as a real directory with
    # per-file absolute symlinks inside — same shape the tree artifact
    # already has in runfiles, so no new materialisation cost.
    #
    # Hop 2 is a `declare_symlink` with a relative `target_path`. Relative
    # depth is identical in bazel-bin and runfiles because the target
    # stays entirely within the venv's own output tree. This is what
    # unblocks `py_image_layer` (which walks bazel-bin) and any other
    # bazel-bin-walking tool.
    site_packages_to_venv_root = "/".join([".."] * 3)
    site_packages_to_wheels_root = site_packages_to_venv_root + "/_wheels"

    # Map from site_packages_rfpath → wheel key for wheels that carry
    # install_tree. The key is an 8-hex hash of the wheel's
    # `install_tree.short_path` (globally unique among File objects), so:
    #
    #   * adding/removing a wheel doesn't shift the keys of other wheels
    #     → unaffected Hop 1 actions and .pth lines stay byte-identical
    #     → better remote-cache reuse for downstream consumers
    #     (py_image_layer, py_venv_exec) that take the venv as input;
    #   * paths are stable across builds for the same wheel, which makes
    #     debugging (and key-aware tooling) deterministic.
    #
    # We fail loudly on the rare 32-bit hash collision; the caller can
    # widen the key or rename a wheel rule.
    wheels_with_trees = [w for w in wheels if getattr(w, "install_tree", None) != None]
    wheel_key_by_sp = {}
    wheel_by_key = {}
    for w in wheels_with_trees:
        key = _wheel_key(w)
        prior = wheel_by_key.get(key)
        if prior != None and prior.install_tree.short_path != w.install_tree.short_path:
            fail("venv wheel key collision on '{}': {} vs {}".format(
                key,
                prior.install_tree.short_path,
                w.install_tree.short_path,
            ))
        wheel_by_key[key] = w
        wheel_key_by_sp[w.site_packages_rfpath] = key

    declared = []  # accumulator for all outputs

    # Hop 1: per-wheel directory under _wheels/<key>/. Bazel picks an
    # absolute path under bazel-bin; the output is a tree artifact whose
    # contents dereference the install_tree.
    for w in wheels_with_trees:
        key = wheel_key_by_sp[w.site_packages_rfpath]
        wheel_dir = ctx.actions.declare_directory(
            "{}/_wheels/{}".format(venv_name, key),
        )
        ctx.actions.symlink(
            output = wheel_dir,
            target_file = w.install_tree,
        )
        declared.append(wheel_dir)

    # Hop 2 (+ legacy one-hop fallback): per-top-level site-packages
    # symlinks. If the owning wheel has a `_wheels/<key>/` entry, we
    # route through it with an intra-venv relative path; otherwise fall
    # back to the historical runfiles-root-escape unresolved symlink.
    # Keys may be `/`-joined paths below the site-packages root (merged
    # namespace packages, e.g. `jaraco/functools`); each extra path
    # segment needs one more `..` to escape back up.
    for tl, wheel_site_pkgs in top_level_to_site_pkgs.items():
        out = ctx.actions.declare_symlink("{}/{}".format(site_packages_rel, tl))
        extra_up = "../" * tl.count("/")
        key = wheel_key_by_sp.get(wheel_site_pkgs)
        if key != None:
            ctx.actions.symlink(
                output = out,
                target_path = "{}{}/{}/lib/{}/site-packages/{}".format(
                    extra_up,
                    site_packages_to_wheels_root,
                    key,
                    wheel_py_ver,
                    tl,
                ),
            )
        else:
            ctx.actions.symlink(
                output = out,
                target_path = "{}{}/{}/{}".format(extra_up, escape, wheel_site_pkgs, tl),
            )
        declared.append(out)

    # Physical merges for regular packages that span wheels (see
    # _resolve_wheel_collisions). Each complete top-level namespace is one
    # TreeArtifact under _merged, with a site-packages symlink for static
    # tools. The explicit boundary lets packaging consumers classify the
    # derived wheel content without guessing from ordinary venv paths.
    #
    # The merge runs as a build action under the exec-configuration
    # interpreter (same shape as WhlInstall's unpack action). A claimant
    # without an install_tree can remain on the .pth fallback when
    # it is unrelated to the regular-package conflict. A required claimant
    # cannot: omitting it would silently produce an incomplete package.
    merged_runfiles_roots = []
    dependency_files = []
    for group in merge_groups:
        if group.missing_required_site_packages:
            fail(("{}: wheels {} are required to merge the top-level package `{}` " +
                  "but do not expose install_tree outputs.").format(
                ctx.label,
                group.missing_required_site_packages,
                group.root,
            ))
        if site_merge_script_py == None:
            fail(("{}: wheels {} all contribute to the regular package `{}` — merging it " +
                  "requires the venv rule to supply the site_merge tool.").format(
                ctx.label,
                group.site_packages_list,
                group.root,
            ))
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

        merged_tree = ctx.actions.declare_directory(
            "{}/_merged/{}".format(venv_name, group.root),
        )
        arguments = ctx.actions.args()
        arguments.add(site_merge_script_py)
        arguments.add_all(
            [merged_tree],
            expand_directories = False,
            before_each = "--into",
            format_each = "%s/" + group.root,
        )
        arguments.add("--collision-policy", package_collisions)
        trees = []
        for sp in group.site_packages_list:
            key = wheel_key_by_sp.get(sp)
            if key == None:
                fail("{}: wheel at {} contributes to merged package `{}` but has no install_tree.".format(
                    ctx.label,
                    sp,
                    group.root,
                ))
            tree = wheel_by_key[key].install_tree
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
            outputs = [merged_tree],
            execution_requirements = {
                "supports-path-mapping": "1",
            },
        )
        merged_link = ctx.actions.declare_symlink("{}/{}".format(site_packages_rel, group.root))
        ctx.actions.symlink(
            output = merged_link,
            target_path = "{}/_merged/{}/{}".format(
                site_packages_to_venv_root,
                group.root,
                group.root,
            ),
        )
        declared.extend([merged_tree, merged_link])
        dependency_files.append(merged_tree)
        merged_runfiles_roots.append(to_rlocation_path(ctx, merged_tree))

    # Keyed wheels (have `_wheels/<key>/`) emit a plain relative path:
    # site.py joins it with the .pth's directory and appends to
    # sys.path. Safe because root `*.pth` filenames are depth-1 RECORD
    # entries that Hop 2 already symlinked at the venv root. Non-keyed
    # wheels (`py_unpacked_wheel` without `top_levels`) emit
    # `site.addsitedir` so wheel-root `.pth` shims still fire — a
    # plain path entry would skip the .pth scan. First-party imports
    # emit a plain path line.
    def _format_imp(imp):
        if imp in fully_covered_site_pkgs:
            return None
        if imp.endswith("site-packages"):
            key = wheel_key_by_sp.get(imp)
            if key != None:
                return "{wheels_root}/{key}/lib/{py_ver}/site-packages".format(
                    wheels_root = site_packages_to_wheels_root,
                    key = key,
                    py_ver = wheel_py_ver,
                )
            return ("import os, sys, site; " +
                    "site.addsitedir(os.path.normpath(os.path.join(" +
                    "sys.prefix, \"{venv_escape}\", \"{imp}\")))").format(
                venv_escape = venv_to_runfiles_escape,
                imp = imp,
            )
        return "{}/{}".format(escape, imp)

    def _format_first_party_imp(imp):
        return None if imp.endswith("site-packages") else imp

    runfiles_imports = ctx.actions.declare_file(
        "{}/_aspect_rules_py_imports.py".format(site_packages_rel),
    )
    ctx.actions.symlink(
        output = runfiles_imports,
        target_file = runfiles_imports_py,
    )
    runfiles_import_roots = ctx.actions.declare_file(
        "{}/_aspect_rules_py_imports.txt".format(site_packages_rel),
    )
    runfiles_import_root_lines = ctx.actions.args()
    runfiles_import_root_lines.use_param_file("%s", use_always = True)
    runfiles_import_root_lines.set_param_file_format("multiline")
    runfiles_import_root_lines.add(venv_to_runfiles_escape)
    runfiles_import_root_lines.add_all(merged_runfiles_roots)
    runfiles_import_root_lines.add_all(
        imports_depset,
        map_each = _format_first_party_imp,
        allow_closure = True,
    )
    ctx.actions.write(
        output = runfiles_import_roots,
        content = runfiles_import_root_lines,
    )
    runfiles_imports_pth = ctx.actions.declare_file(
        "{}/00_aspect_rules_py_imports.pth".format(site_packages_rel),
    )
    ctx.actions.write(
        output = runfiles_imports_pth,
        content = "import _aspect_rules_py_imports; _aspect_rules_py_imports.initialize()\n",
    )
    declared.extend([
        runfiles_imports,
        runfiles_import_roots,
        runfiles_imports_pth,
    ])

    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")
    pth_lines.add(escape)

    # allow_closure lets _format_imp capture fully_covered_site_pkgs / wheel_key_by_sp
    # so we don't have to materialise imports_depset via .to_list().
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
        dependency_files = dependency_files,
        site_packages_pth_file = site_packages_pth_file,
        pyvenv_cfg = pyvenv_cfg,
    )
