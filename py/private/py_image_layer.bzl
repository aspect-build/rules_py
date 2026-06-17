"""py_image_layer — analysis-time grouped OCI layers with globally shared pip tars.

Two rule-propagated aspects wire onto `py_image_layer.binary`:

  1. `_layer_aspect` — propagates through `deps`/`data`/`actual`. For pip packages it
     creates aspect-owned per-package tars at the pip target's namespace (globally
     shared across every rule using that package) for solo whole-groups and subpath
     splits. Members of multi-member whole groups get NO per-package tar — intermediate
     elided; they just flag `merge_group` on their _LayerInfo struct. First-party
     PyInfo targets matched by `py_layer_tier.groups` are captured as `first_party_layers`
     entries (label, files, group) to be tarred per-group at the binary. Produces
     `_LayerInfo`.

  2. `_merge_aspect` — runs only on the binary (`attr_aspects = []`), after `_layer_aspect`
     via `required_aspect_providers`. Reads `_LayerInfo.pip_packages` (full closure),
     buckets install_dirs by `merge_group`, and emits one bsdtar action per group from
     raw install_dirs — single pass, no intermediates, content exactly matches closure
     (no dep leak). Produces `_MergedLayerInfo` declared at the binary's output namespace.

Layer tier (groups + compression) is carried by the `py_layer_tier` rule which produces
`PyLayerTierInfo`. Aspects read it via a private `_layer_tier` attr whose default is
`//py:layer_tier` (a label_flag). Users switch tiers globally via
`--//py:layer_tier=//path:custom_tier`.

Sharing model:
  - Solo whole-group + subpath-split pip tars: action-shared across every rule using
    that package (declared at the pip target's namespace).
  - Multi-member merged tars: per-binary action, but deterministic content (canonical
    mtree, fixed bsdtar options) → remote CAS / OCI registry dedupe by digest.
  - First-party grouped tars: per-binary action, one tar per group, collected from
    matched py_library targets in the binary's dep closure.
  - Ungrouped pip packages and generated venv dependency overlays: squashed
    by the rule into one per-rule tar.
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

_TAR_TOOLCHAIN = "@tar.bzl//tar/toolchain:type"

# whl_install repo names embed the pip package as
# `<separator>whl_install__<hash>__<package>__<...>`. The `<separator>` differs
# between Bazel 8 (`+`) and Bazel 9 (`~`); `whl_install__` is the stable
# anchor we match on, which works under both.
def _extract_whl_install_pkg(label_str):
    """Extract the pip package name from a whl_install repo label.

    Returns the canonical pip package name if `label_str` lives inside a
    whl_install repo; otherwise returns None. Tolerates both Bazel 8
    (`+`) and Bazel 9 (`~`) module-extension separators.
    """
    marker = "whl_install__"
    idx = label_str.find(marker)
    if idx < 0:
        return None
    rest = label_str[idx + len(marker):].split("//", 1)[0]
    parts = rest.split("__")
    if len(parts) < 2:
        return None
    return parts[1]

def normalize_label(label_str):
    """Canonicalize a label so user-supplied strings match `str(target.label)`.

    Rewrites whl_install labels to '@pip//<pkg>', strips the '@@//' prefix,
    and expands implicit target names ('//foo/bar' → '//foo/bar:bar').

    This function is idempotent: normalize_label(normalize_label(x)) == normalize_label(x).

    Callers inside aspects pass str(target.label), whose canonical form varies by
    Bazel version (+/~ separator). The whl_install__ anchor is stable across both.

    Args:
        label_str: str(target.label) from Bazel analysis, or a user-supplied label string.

    Returns:
        The canonicalized label string suitable for dict lookup against py_layer_tier keys.
    """
    label_str = str(label_str)
    pkg = _extract_whl_install_pkg(label_str)
    if pkg != None:
        label_str = "@pip//" + pkg
    if label_str.startswith("@@//"):
        label_str = label_str[2:]
    parts = label_str.split("//", 1)
    if len(parts) == 2 and parts[1] and ":" not in parts[1]:
        target_name = parts[1].rsplit("/", 1)[-1]
        label_str = label_str + ":" + target_name
    return label_str

PyLayerTierInfo = provider(
    doc = "Layer tier for py_image_layer: how pip packages are grouped and compressed.",
    fields = {
        "whole_groups": "dict[str, str] — normalized pip label → group name.",
        "subpath_groups": "dict[str, dict[str, list[str]]] — label → {group_name: [glob_patterns]}.",
        "compression": "dict[str, list[str]] — group name → [algorithm, level].",
        "multi_member_groups": "dict[str, True] — group names with 2+ members in whole_groups.",
        "interpreter_group": "str — group name for the Python interpreter layer; '' disables.",
        "root": "str — root path in the image (e.g. '/app').",
        "strip_prefix": "str — prefix stripped from source file paths; empty means use binary short_path.",
    },
)

def _split_glob_key(key):
    """If key is '@pip//pkg:glob', return (label, pattern); else return (None, None)."""
    colon_idx = key.rfind(":")
    if colon_idx > 0 and ("*" in key[colon_idx:] or "?" in key[colon_idx:]):
        return key[:colon_idx], key[colon_idx + 1:]
    return None, None

def _py_layer_tier_impl(ctx):
    whole_groups = {}
    subpath_groups = {}
    for key, group_name in ctx.attr.groups.items():
        label_part, pattern = _split_glob_key(key)
        if pattern != None:
            subpath_groups.setdefault(normalize_label(label_part), {}).setdefault(group_name, []).append(pattern)
        else:
            whole_groups[normalize_label(key)] = group_name

    group_counts = {}
    for group_name in whole_groups.values():
        group_counts[group_name] = group_counts.get(group_name, 0) + 1
    multi_member_groups = {name: True for name, count in group_counts.items() if count >= 2}

    return [PyLayerTierInfo(
        whole_groups = whole_groups,
        subpath_groups = subpath_groups,
        compression = dict(ctx.attr.compression),
        multi_member_groups = multi_member_groups,
        interpreter_group = ctx.attr.interpreter_group,
        root = ctx.attr.root,
        strip_prefix = ctx.attr.strip_prefix,
    )]

py_layer_tier = rule(
    implementation = _py_layer_tier_impl,
    attrs = {
        "groups": attr.string_dict(
            default = {},
            doc = ("Maps @pip//package → group name (whole pip package), " +
                   "@pip//package:glob → group name (pip subpath split), or " +
                   "//some/first_party:lib → group name (first-party PyInfo target). " +
                   "First-party main-repo labels may be written as //pkg:name; " +
                   "fully-qualified forms like @@//pkg:name are also accepted. " +
                   "A pip package may appear as a whole-package key OR with subpath globs, not both."),
        ),
        "compression": attr.string_list_dict(
            default = {},
            doc = ("Maps group name → [algorithm, level] for pip-derived layers. " +
                   "Applies to the whole-group tar, each subpath-split tar, and the " +
                   "multi-member merged tar — anything routed through py_layer_tier.groups. " +
                   "Example: {\"heavy_pkgs\": [\"zstd\", \"1\"]}. Untouched groups default to gzip -6."),
        ),
        "interpreter_group": attr.string(
            default = "",
            doc = ("When non-empty, the Python interpreter runfiles resolved from the " +
                   "binary's py toolchain are emitted as their own layer under this name " +
                   "instead of being bundled into the default source layer."),
        ),
        "root": attr.string(
            default = "/app",
            doc = "Root path in the image. Default: '/app'.",
        ),
        "strip_prefix": attr.string(
            default = "",
            doc = "Prefix stripped from source file paths. Empty means use the binary's short_path.",
        ),
    },
    provides = [PyLayerTierInfo],
)

_LayerInfo = provider(
    doc = "Private: aggregated source files + pip package layers produced by _layer_aspect.",
    fields = {
        "source_files": "depset[File] — ungrouped first-party Python source files.",
        "pip_packages": "depset[struct] — fully transitive pip packages with per-package layers.",
        "venv_dependency_files": "depset[File] — generated third-party overlays owned by a venv-producing rule.",
        "first_party_layers": "depset[struct(label, files, group)] — first-party PyInfo targets matched by py_layer_tier.groups.",
        "interpreter_files": "depset[File] — interpreter runfiles, populated only on the py toolchain pass for the binary-branch skip filter.",
        "interpreter_layer": "struct(tar, group) | None — prebuilt interpreter layer tar + its group name, declared at the toolchain target's namespace so the tar action-shares across every py_image_layer using that toolchain config.",
    },
)

_PY_VENV_KINDS = ("py_venv", "_py_venv")

def _collect_from_deps(ctx, provider):
    """Walk deps/data/actual/venv and return a list of provider values from each matching dep."""
    results = []
    for attr_name in ["deps", "data"]:
        for dep in getattr(ctx.rule.attr, attr_name, []):
            if provider in dep:
                results.append(dep[provider])

    # `py_venv_exec` (the rule the `py_binary` macro expands to) routes srcs /
    # deps onto a sibling `py_venv` reached via the `venv` attr, so the aspect
    # must hop through it to see the binary's actual dep closure.
    venv = getattr(ctx.rule.attr, "venv", None)
    if venv != None and provider in venv:
        results.append(venv[provider])
    actual = getattr(ctx.rule.attr, "actual", None)
    if actual != None and type(actual) != "list":
        if provider in actual:
            results.append(actual[provider])
    elif actual:
        for dep in actual:
            if provider in dep:
                results.append(dep[provider])
    return results

def _compression_for(plan, group_name):
    comp = plan.compression.get(group_name, None) if group_name else None
    algorithm = comp[0] if comp else "gzip"
    level = comp[1] if comp else "6"
    ext = ".tar.zst" if algorithm == "zstd" else ".tar.gz"
    return algorithm, level, ext

def _tar_toolchain(ctx):
    tc = ctx.toolchains[_TAR_TOOLCHAIN]
    return tc.tarinfo, tc.default

def _build_pip_layers(ctx, plan, label, install_dir):
    """Declare per-package pip tars for one wheel target.

    Returns (layers, merge_group): layers is a tuple of struct(tar, group)
    entries for this package; merge_group is set (and layers is empty) iff
    the package is deferred to `_merge_aspect`.
    """
    subpath_for_this = plan.subpath_groups.get(label, {})
    whole_group = plan.whole_groups.get(label, None)
    is_multi_member = whole_group != None and whole_group in plan.multi_member_groups

    if is_multi_member and subpath_for_this:
        fail(("py_layer_tier bug for %s: package is a member of multi-member group %r and " +
              "also has subpath group entries. A pip package may be in a multi-member group OR " +
              "have subpath splits, not both.") % (label, whole_group))

    if is_multi_member:
        return ((), whole_group)

    if not subpath_for_this and whole_group == None:
        return ((), None)

    bsdtar, bsdtar_files = _tar_toolchain(ctx)
    layers = []

    if subpath_for_this:
        all_patterns = [p for pats in subpath_for_this.values() for p in pats]
        for grp_name, patterns in subpath_for_this.items():
            algorithm, level, ext = _compression_for(plan, grp_name)
            tar_out = ctx.actions.declare_file("_pip_layer_{}{}".format(grp_name, ext))
            _run_tar_action(
                ctx,
                bsdtar,
                bsdtar_files,
                tar_out,
                install_dir,
                _make_glob_map_each(patterns),
                algorithm,
                level,
                {},
                "PyImagePkgLayer",
                "Creating pip layer %s[%s]" % (label, grp_name),
            )
            layers.append(struct(tar = tar_out, group = grp_name))

        algorithm, level, ext = _compression_for(plan, whole_group)
        rest_tar = ctx.actions.declare_file("_pip_layer_tar" + ext)
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            rest_tar,
            install_dir,
            _make_glob_map_each(all_patterns, invert = True),
            algorithm,
            level,
            {},
            "PyImagePkgLayer",
            "Creating pip layer %s[rest]" % label,
        )
        layers.append(struct(tar = rest_tar, group = whole_group))
    else:
        algorithm, level, ext = _compression_for(plan, whole_group)
        tar_out = ctx.actions.declare_file("_pip_layer_tar" + ext)
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            tar_out,
            install_dir,
            _pkg_file_to_mtree,
            algorithm,
            level,
            {},
            "PyImagePkgLayer",
            "Creating pip layer %s" % label,
        )
        layers.append(struct(tar = tar_out, group = whole_group))

    return (tuple(layers), None)

def _layer_aspect_impl(target, ctx):
    # Py toolchain pass (reached via toolchains_aspects). Declare the interpreter
    # tar at the toolchain's namespace so it action-shares across every
    # py_image_layer using this (toolchain, config); ctx.rule.toolchains
    # (NOT ctx.toolchains) is how the binary reads it back, which correctly
    # follows the binary's target-platform transition.
    if platform_common.ToolchainInfo in target:
        py3 = getattr(target[platform_common.ToolchainInfo], "py3_runtime", None)
        if py3 == None or py3.files == None:
            return []
        direct = [py3.interpreter] if getattr(py3, "interpreter", None) != None else []
        interp_depset = depset(direct = direct, transitive = [py3.files])
        plan = ctx.attr._layer_tier[PyLayerTierInfo]
        interp_group = plan.interpreter_group
        interp_layer = None
        if interp_group:
            bsdtar, bsdtar_files = _tar_toolchain(ctx)
            algorithm, level, ext = _compression_for(plan, interp_group)
            interp_tar = ctx.actions.declare_file("_interpreter_layer_{}{}".format(interp_group, ext))
            _run_tar_action(
                ctx,
                bsdtar,
                bsdtar_files,
                interp_tar,
                interp_depset,
                _interpreter_file_to_mtree,
                algorithm,
                level,
                {},
                "PyImagePkgLayer",
                "Creating interpreter layer %s" % target.label,
            )
            interp_layer = struct(tar = interp_tar, group = interp_group)
        return [_LayerInfo(
            source_files = depset(),
            pip_packages = depset(),
            venv_dependency_files = depset(),
            first_party_layers = depset(),
            interpreter_files = interp_depset,
            interpreter_layer = interp_layer,
        )]

    dep_infos = _collect_from_deps(ctx, _LayerInfo)
    transitive_source = [info.source_files for info in dep_infos]
    transitive_pkgs = [info.pip_packages for info in dep_infos]
    transitive_venv_dependency_files = [info.venv_dependency_files for info in dep_infos]
    transitive_fp = [info.first_party_layers for info in dep_infos]

    if PyWheelsInfo in target and ctx.rule.kind in ("whl_install", "py_unpacked_wheel"):
        plan = ctx.attr._layer_tier[PyLayerTierInfo]
        label = normalize_label(str(target.label))
        install_dir = depset([w.install_tree for w in target[PyWheelsInfo].wheels.to_list()])
        layers, merge_group = _build_pip_layers(ctx, plan, label, install_dir)

        return [_LayerInfo(
            source_files = depset(transitive = transitive_source),
            pip_packages = depset(
                direct = [struct(
                    label = label,
                    files = install_dir,
                    layers = layers,
                    merge_group = merge_group,
                )],
                transitive = transitive_pkgs,
            ),
            venv_dependency_files = depset(transitive = transitive_venv_dependency_files),
            first_party_layers = depset(transitive = transitive_fp),
        )]

    own_source = []
    own_fp = []
    own_venv_dependency_files = []
    if OutputGroupInfo in target:
        files = getattr(target[OutputGroupInfo], "_venv_dependency_files", None)
        if files != None:
            own_venv_dependency_files.append(files)
    interpreter_layer = None
    kind = ctx.rule.kind
    is_binary = (
        PyInfo in target and
        DefaultInfo in target and
        target[DefaultInfo].files_to_run.executable != None
    )

    # Aliases (and other pure-forwarding wrappers) forward DefaultInfo from
    # `actual`. Reading `target[DefaultInfo].files` here for an alias of a
    # wheel target would re-introduce the install_tree as a source file — but
    # it is already captured upstream as a pip package via the wheel-leaf
    # branch. Just propagate transitively for these targets.
    if kind == "alias":
        return [_LayerInfo(
            source_files = depset(transitive = transitive_source),
            pip_packages = depset(transitive = transitive_pkgs),
            venv_dependency_files = depset(transitive = transitive_venv_dependency_files),
            first_party_layers = depset(transitive = transitive_fp),
        )]

    venv_dependency_files = depset(
        transitive = transitive_venv_dependency_files + own_venv_dependency_files,
    )

    # Skip PyInfo deps (including wheel-leaf targets, which also emit PyInfo) —
    # they self-capture via the aspect.
    if kind not in _PY_VENV_KINDS and PyInfo in target and not is_binary:
        own_parts = [target[DefaultInfo].files]
        for attr_name in ("data", "deps"):
            attr_val = getattr(ctx.rule.attr, attr_name, None)
            if not attr_val:
                continue
            for dep in attr_val:
                if PyInfo in dep:
                    continue
                if DefaultInfo in dep:
                    own_parts.append(dep[DefaultInfo].files)
        own_depset = depset(transitive = own_parts)

        plan = ctx.attr._layer_tier[PyLayerTierInfo]
        label_str = normalize_label(str(target.label))
        fp_group = plan.whole_groups.get(label_str, None)
        if fp_group != None:
            own_fp.append(struct(
                label = label_str,
                files = own_depset,
                group = fp_group,
            ))
        else:
            own_source.append(own_depset)

    # Binaries walk their runfiles for the source layer, filtering out bytes already
    # shipping in their own pip / fp-group / interpreter layers.
    if is_binary:
        if PyInfo not in target:
            own_source.append(target[DefaultInfo].files)
        skip_paths = {}
        for pkg_depset in transitive_pkgs:
            for pkg in pkg_depset.to_list():
                for f in pkg.files.to_list():
                    skip_paths[f.path] = True
        for fp_depset in transitive_fp:
            for entry in fp_depset.to_list():
                for f in entry.files.to_list():
                    skip_paths[f.path] = True
        for f in venv_dependency_files.to_list():
            skip_paths[f.path] = True

        # Opt-in interpreter layer. The aspect fires on the py toolchain via
        # `toolchains_aspects` and declares the tar there; we just read the
        # pre-built File out of the toolchain's _LayerInfo via ctx.rule.toolchains
        # (NOT ctx.toolchains, which would pick the exec interpreter under
        # cross-platform transitions) and propagate it up to the rule impl.
        interp_paths = {}
        if PY_TOOLCHAIN in ctx.rule.toolchains:
            py_tc = ctx.rule.toolchains[PY_TOOLCHAIN]
            if _LayerInfo in py_tc:
                tc_info = py_tc[_LayerInfo]
                interpreter_layer = tc_info.interpreter_layer

                # Only skip interpreter paths from the source layer when there
                # IS a separate interpreter tar to route them to; otherwise the
                # interpreter belongs in the default layer.
                if interpreter_layer != None and tc_info.interpreter_files != None:
                    for f in tc_info.interpreter_files.to_list():
                        interp_paths[f.path] = True

        runfiles_files = target[DefaultInfo].default_runfiles.files.to_list()
        filtered = [f for f in runfiles_files if f.path not in skip_paths and f.path not in interp_paths]
        if filtered:
            own_source.append(depset(direct = filtered))

        # bzlmod-canonical → apparent repo-name translation manifest.
        # `runfiles.bash`/`rlocation` need this at `<binary>.runfiles/_repo_mapping`
        # to resolve apparent labels (e.g. `aspect_rules_py/...`) to the canonical
        # repo names (`aspect_rules_py+/...`) under which files are actually staged.
        # Without it the launcher fails with "runfiles.bash initializer cannot find
        # bazel_tools/tools/bash/runfiles/runfiles.bash" the moment any rlocation
        # call is evaluated.
        repo_mapping = getattr(target[DefaultInfo].default_runfiles, "repo_mapping_manifest", None)
        if repo_mapping != None:
            own_source.append(depset(direct = [repo_mapping]))

    return [_LayerInfo(
        source_files = depset(transitive = transitive_source + own_source),
        pip_packages = depset(transitive = transitive_pkgs),
        venv_dependency_files = venv_dependency_files,
        first_party_layers = depset(direct = own_fp, transitive = transitive_fp),
        interpreter_layer = interpreter_layer,
    )]

_layer_aspect = aspect(
    implementation = _layer_aspect_impl,
    attr_aspects = ["deps", "data", "actual", "venv"],
    attrs = {
        "_layer_tier": attr.label(
            default = "//py:layer_tier",
            providers = [PyLayerTierInfo],
        ),
        "_awk_script": attr.label(
            default = "//py/private:modify_mtree.awk",
            allow_single_file = True,
        ),
        "_awk": attr.label(
            default = "@gawk",
            cfg = "exec",
            executable = True,
        ),
    },
    toolchains = [_TAR_TOOLCHAIN],
    toolchains_aspects = [PY_TOOLCHAIN],
    provides = [_LayerInfo],
)

_MergedLayerInfo = provider(
    doc = "Private: closure-filtered merged tars for multi-member groups, produced by _merge_aspect.",
    fields = {
        "merged_tars": "dict[group_name, File] — one merged tar per multi-member group.",
    },
)

def _merge_aspect_impl(target, ctx):
    info = target[_LayerInfo]

    bucket = {}
    seen = {}
    for pkg in info.pip_packages.to_list():
        if pkg.label in seen:
            continue
        seen[pkg.label] = True
        if pkg.merge_group != None:
            bucket.setdefault(pkg.merge_group, []).append(pkg.files)

    if not bucket:
        return [_MergedLayerInfo(merged_tars = {})]

    bsdtar, bsdtar_files = _tar_toolchain(ctx)
    plan = ctx.attr._layer_tier[PyLayerTierInfo]

    merged_tars = {}
    for group_name in sorted(bucket):
        install_dirs = bucket[group_name]
        algorithm, level, ext = _compression_for(plan, group_name)
        tar_out = ctx.actions.declare_file("_merged_pip_layer_{}{}".format(group_name, ext))
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            tar_out,
            depset(transitive = install_dirs),
            _pkg_file_to_mtree,
            algorithm,
            level,
            {},
            "PyImageMergedLayer",
            "Merging %d pip packages into %s[%s]" % (len(install_dirs), target.label, group_name),
        )
        merged_tars[group_name] = tar_out

    return [_MergedLayerInfo(merged_tars = merged_tars)]

_merge_aspect = aspect(
    implementation = _merge_aspect_impl,
    attr_aspects = [],
    attrs = {
        "_layer_tier": attr.label(
            default = "//py:layer_tier",
            providers = [PyLayerTierInfo],
        ),
        "_awk_script": attr.label(
            default = "//py/private:modify_mtree.awk",
            allow_single_file = True,
        ),
        "_awk": attr.label(
            default = "@gawk",
            cfg = "exec",
            executable = True,
        ),
    },
    toolchains = [_TAR_TOOLCHAIN],
    required_aspect_providers = [[_LayerInfo]],
    provides = [_MergedLayerInfo],
)

def _apply_strip_prefix(sp, strip_prefix, root):
    prefix = strip_prefix.replace("\\/", "/")
    if sp == prefix:
        return "." + root

    # `prefix + "."` catches the binary's own `*.runfiles/...` tree; `prefix + "/"`
    # catches files actually under a directory named `prefix`.
    if sp.startswith(prefix + ".") or sp.startswith(prefix + "/"):
        return "." + root + sp[len(prefix):]
    return "./app.runfiles/_main/" + sp

def _file_to_mtree_entry(f, mode = "0644", strip_prefix = "", root = "/", maybe_symlink = False):
    sp = f.short_path
    if sp == "_repo_mapping":
        # Bazel synthesizes a top-level `_repo_mapping` runfile (no `_main/`
        # prefix); replicate that placement so runfiles.bash can find it.
        dst = "./app.runfiles/_repo_mapping"
    elif sp.startswith("../"):
        dst = "./app.runfiles/" + sp[3:]
    elif strip_prefix:
        dst = _apply_strip_prefix(sp, strip_prefix, root)
    else:
        dst = "./app.runfiles/_main/" + sp

    # `f.is_symlink` emits `type=link` (awk readlinks once); `maybe_symlink=True`
    # emits `type=file content=` (awk readlinks to detect repo-rule-staged
    # symlinks); default emits `type=file contents=` which skips awk entirely.
    if f.is_symlink:
        return "{} type=link mode={} uid=0 gid=0 time=1672560000 link={}".format(
            dst.replace(" ", "\\040"),
            mode,
            f.path.replace(" ", "\\040"),
        )
    marker = "content" if maybe_symlink else "contents"
    return "{} type=file mode={} uid=0 gid=0 time=1672560000 {}={}".format(
        dst.replace(" ", "\\040"),
        mode,
        marker,
        f.path.replace(" ", "\\040"),
    )

def _source_file_to_mtree(f, dir_expander, strip_prefix, root, maybe_symlink):
    # 0755 throughout: keeps launcher/interpreter/venv shims executable; Bazel
    # doesn't expose per-input source mode for us to propagate.
    if f.is_directory:
        return [
            _file_to_mtree_entry(child, "0755", strip_prefix, root, maybe_symlink)
            for child in dir_expander.expand(f)
        ]
    return _file_to_mtree_entry(f, "0755", strip_prefix, root, maybe_symlink)

def _user_file_to_mtree(f, dir_expander):
    if f.is_directory:
        return [_file_to_mtree_entry(child, "0755") for child in dir_expander.expand(f)]
    return _file_to_mtree_entry(f, "0644")

def _should_skip_pkg_path(p):
    return (
        "dist-info/RECORD" in p or "dist-info/INSTALLER" in p or
        "dist-info/WHEEL" in p or "dist-info/REQUESTED" in p or
        "/__pycache__/" in p or p.endswith(".whl")
    )

def _pkg_file_to_mtree(f, dir_expander):
    if f.is_directory:
        lines = []
        for child in dir_expander.expand(f):
            p = child.path
            if _should_skip_pkg_path(p):
                continue
            lines.append(_file_to_mtree_entry(child, "0755"))
        return lines
    return [_file_to_mtree_entry(f, "0755")]

def _interpreter_file_to_mtree(f, dir_expander):
    # Interpreter repo stages `bin/python -> python3.11` symlinks `f.is_symlink`
    # doesn't catch, so opt into awk's readlink scan.
    if f.is_directory:
        lines = []
        for child in dir_expander.expand(f):
            p = child.path
            if _should_skip_pkg_path(p):
                continue
            lines.append(_file_to_mtree_entry(child, "0755", maybe_symlink = True))
        return lines
    return [_file_to_mtree_entry(f, "0755", maybe_symlink = True)]

def _glob_match_chunk(name, chunk):
    if chunk == "*":
        return True
    if "*" not in chunk:
        return name == chunk
    if chunk.count("*") > 2:
        fail("Glob chunks with more than two asterisks are unsupported: " + chunk)
    if chunk.count("*") == 2:
        left, middle, right = chunk.split("*")
    else:
        middle = ""
        left, right = chunk.split("*")
    return (
        name.startswith(left) and
        name.endswith(right) and
        len(left) + len(right) <= len(name) and
        (not middle or middle in name[len(left):len(name) - len(right)])
    )

def _glob_match(path, pattern):
    path_parts = path.split("/")
    pattern_parts = pattern.split("/")
    if len(path_parts) < len(pattern_parts):
        return False
    for i in range(len(pattern_parts)):
        if not _glob_match_chunk(path_parts[-(i + 1)], pattern_parts[-(i + 1)]):
            return False
    return True

def _make_glob_map_each(patterns, invert = False):
    def _matches(p):
        hit = any([_glob_match(p, pat) for pat in patterns])
        return hit != invert

    def _fn(f, dir_expander):
        if f.is_directory:
            lines = []
            for child in dir_expander.expand(f):
                p = child.path
                if _should_skip_pkg_path(p):
                    continue
                if _matches(p):
                    lines.append(_file_to_mtree_entry(child, "0755"))
            return lines
        if _matches(f.path):
            return [_file_to_mtree_entry(f, "0755")]
        return []

    return _fn

def _parse_exec_requirements(entries):
    reqs = {}
    for entry in entries:
        k, _, v = entry.partition("=")
        reqs[k] = v
    return reqs

def _platform_cfg_impl(settings, attr):
    result = {
        "//command_line_option:platforms": [attr.platform] if attr.platform else settings["//command_line_option:platforms"],
        "@aspect_rules_py//py:layer_tier": str(attr.layer_tier) if attr.layer_tier else settings["@aspect_rules_py//py:layer_tier"],
    }
    return result

_platform_cfg = transition(
    implementation = _platform_cfg_impl,
    inputs = ["//command_line_option:platforms", "@aspect_rules_py//py:layer_tier"],
    outputs = ["//command_line_option:platforms", "@aspect_rules_py//py:layer_tier"],
)

def _run_tar_action(ctx, bsdtar, bsdtar_files, tar_out, files_depset, map_each, compress, level, reqs, mnemonic, progress_msg):
    # mtree (param file) → gawk (readlinks `type=link`/`type=file content=`
    # rows; `contents=` rows pass through; END buffers, asort-sorts, and
    # writes the sorted mtree to a file) → bsdtar consumes the file.
    # No shell wrapper, no `sort` host dep.
    mtree_args = ctx.actions.args()
    mtree_args.set_param_file_format("multiline")
    mtree_args.use_param_file("%s", use_always = True)
    mtree_args.add("#mtree")
    mtree_args.add_all(files_depset, map_each = map_each, expand_directories = False, allow_closure = True)

    awk_script = ctx.file._awk_script
    awk = ctx.executable._awk
    sorted_mtree = ctx.actions.declare_file(tar_out.basename + ".mtree", sibling = tar_out)

    gawk_args = ctx.actions.args()
    gawk_args.add("-v", sorted_mtree, format = "outfile=%s")
    gawk_args.add("-f", awk_script)
    ctx.actions.run(
        executable = awk,
        inputs = depset(direct = [awk_script], transitive = [files_depset]),
        outputs = [sorted_mtree],
        arguments = [gawk_args, mtree_args],
        # LC_ALL=C makes gawk's asort byte-stable.
        env = {"LC_ALL": "C"},
        mnemonic = mnemonic + "Mtree",
        progress_message = "Resolving symlinks for %{output}",
        execution_requirements = reqs,
    )

    tar_args = ctx.actions.args()
    tar_args.add("--create")
    tar_args.add("--" + compress)
    tar_args.add("--options", "{}:compression-level={}".format(compress, level))
    tar_args.add("--file", tar_out)

    # `@<file>` tells bsdtar to read the named file as an mtree archive
    # (same as `@-` for stdin, just from disk).
    tar_args.add(sorted_mtree, format = "@%s")
    ctx.actions.run(
        executable = bsdtar.binary,
        inputs = depset(direct = [sorted_mtree], transitive = [files_depset, bsdtar_files.files]),
        outputs = [tar_out],
        arguments = [tar_args],
        mnemonic = mnemonic,
        progress_message = progress_msg,
        execution_requirements = reqs,
        toolchain = _TAR_TOOLCHAIN,
        use_default_shell_env = False,
    )

def _declare_group_tar(ctx, bsdtar, bsdtar_files, out_name, group_name, files, map_each, progress):
    tar_out = ctx.actions.declare_file(out_name)
    level = ctx.attr.group_compress_levels.get(group_name, "6")
    reqs = _parse_exec_requirements(ctx.attr.group_execution_requirements.get(group_name, []))
    _run_tar_action(
        ctx,
        bsdtar,
        bsdtar_files,
        tar_out,
        files,
        map_each,
        "gzip",
        level,
        reqs,
        "PyImageLayer",
        progress,
    )
    return tar_out

def _py_image_layer_impl(ctx):
    info = ctx.attr.binary[_LayerInfo]
    merged = ctx.attr.binary[_MergedLayerInfo]
    bsdtar, bsdtar_files = _tar_toolchain(ctx)

    pkg_by_label = {}
    for pkg in info.pip_packages.to_list():
        if pkg.label not in pkg_by_label:
            pkg_by_label[pkg.label] = pkg
    all_pkgs = pkg_by_label.values()

    layer_tier = ctx.attr.layer_tier if ctx.attr.layer_tier else ctx.attr._layer_tier
    plan = layer_tier[PyLayerTierInfo]
    root = plan.root
    strip_prefix = plan.strip_prefix

    # 3p pip layers are action-shared across the graph and hard-code their
    # destination under `./app.runfiles/<repo>/...`, so the consumer's source
    # layer has to land under the same `/app.runfiles/` tree for the launcher
    # to find them. Default the binary's `short_path` to `strip_prefix` so the
    # natural runfile layout maps onto `./app.runfiles/_main/...` without each
    # caller wiring it up.
    binary_short_path = ctx.attr.binary[DefaultInfo].files_to_run.executable.short_path
    if not strip_prefix:
        strip_prefix = binary_short_path

    all_tars = []

    # Without a dedicated interpreter tar, repo-rule-staged symlinks like
    # rules_python's `bin/python -> python3.11` end up in the source layer
    # and need awk's readlink scan to be preserved.
    source_maybe_symlink = info.interpreter_layer == None

    def _source_map(f, d):
        return _source_file_to_mtree(f, d, strip_prefix, root, source_maybe_symlink)

    rule_group_names = {gname: True for gname in ctx.attr.groups.values()}
    for dep, group_name in ctx.attr.groups.items():
        dep_label = normalize_label(str(dep.label))
        if dep_label in pkg_by_label:
            continue
        tar_out = _declare_group_tar(
            ctx,
            bsdtar,
            bsdtar_files,
            "{}_{}.tar.gz".format(ctx.attr.name, group_name),
            group_name,
            dep[DefaultInfo].files,
            _user_file_to_mtree,
            "Creating image layer %s[%s]" % (ctx.label, group_name),
        )
        all_tars.append(tar_out)

    fp_by_group = {}
    seen_fp_labels = {}
    for entry in info.first_party_layers.to_list():
        if entry.label in seen_fp_labels:
            continue
        seen_fp_labels[entry.label] = True
        fp_by_group.setdefault(entry.group, []).append(entry.files)

    # Slot the pre-built, action-shared interpreter tar into the fp ordering
    # under its group name so users see a stable per-group sort regardless of
    # where the tar was declared.
    prebuilt_group_tars = {}
    if info.interpreter_layer != None:
        prebuilt_group_tars[info.interpreter_layer.group] = info.interpreter_layer.tar
        fp_by_group.setdefault(info.interpreter_layer.group, [])

    for group_name in sorted(fp_by_group):
        if group_name in rule_group_names:
            fail(
                ("Group %r is declared in both py_image_layer.groups and the active " +
                 "py_layer_tier. Pick a unique name — the rule-level group tars ad-hoc " +
                 "deps with a different file layout than first-party sources, so they " +
                 "cannot share a tar.") % group_name,
            )
        if group_name in prebuilt_group_tars:
            tar_out = prebuilt_group_tars[group_name]
        else:
            tar_out = _declare_group_tar(
                ctx,
                bsdtar,
                bsdtar_files,
                "{}_{}.tar.gz".format(ctx.attr.name, group_name),
                group_name,
                depset(transitive = fp_by_group[group_name]),
                _source_map,
                "Creating first-party layer %s[%s]" % (ctx.label, group_name),
            )
        all_tars.append(tar_out)

    for pkg in all_pkgs:
        for layer in pkg.layers:
            all_tars.append(layer.tar)

    for _group_name, merged_tar in sorted(merged.merged_tars.items()):
        all_tars.append(merged_tar)

    ungrouped_pkgs = [p for p in all_pkgs if len(p.layers) == 0 and p.merge_group == None]
    venv_dependency_files = info.venv_dependency_files.to_list()
    if ungrouped_pkgs or venv_dependency_files:
        squashed_tar = _declare_group_tar(
            ctx,
            bsdtar,
            bsdtar_files,
            "{}_squashed.tar.gz".format(ctx.attr.name),
            "packages",
            depset(
                direct = venv_dependency_files,
                transitive = [p.files for p in ungrouped_pkgs],
            ),
            _pkg_file_to_mtree,
            "Creating squashed dependency layer (%d packages, %d venv overlays) for %s" % (
                len(ungrouped_pkgs),
                len(venv_dependency_files),
                ctx.label,
            ),
        )
        all_tars.append(squashed_tar)

    # dep_tars is identical to all_tars except for the source layer appended below;
    # snapshot here to avoid double-bookkeeping during construction.
    dep_tars = list(all_tars)

    source_tar = _declare_group_tar(
        ctx,
        bsdtar,
        bsdtar_files,
        "{}_default.tar.gz".format(ctx.attr.name),
        "default",
        info.source_files,
        _source_map,
        "Creating source layer for %s" % ctx.label,
    )
    all_tars.append(source_tar)

    validation = ctx.actions.declare_file(ctx.attr.name + "_validation.log")
    validation_args = ctx.actions.args()
    validation_args.add("--threshold_mb", str(ctx.attr.warn_remote_cache_threshold_mb))
    validation_args.add("--layer_count", str(len(all_tars)))
    validation_args.add("--warn_layer_count", str(ctx.attr.warn_layer_count))
    validation_args.add("--output", validation)
    for pkg in ungrouped_pkgs:
        validation_args.add_all(pkg.files, format_each = pkg.label + "=%s", expand_directories = False)

    ctx.actions.run(
        executable = ctx.executable._validator,
        inputs = depset(transitive = [pkg.files for pkg in ungrouped_pkgs]),
        outputs = [validation],
        arguments = [validation_args],
        mnemonic = "PyImageLayerValidate",
    )

    return [
        DefaultInfo(files = depset(all_tars)),
        OutputGroupInfo(
            deps = depset(dep_tars),
            sources = depset([source_tar]),
            _validation = depset([validation]),
        ),
    ]

_py_image_layer = rule(
    implementation = _py_image_layer_impl,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            aspects = [_layer_aspect, _merge_aspect],
        ),
        "groups": attr.label_keyed_string_dict(default = {}),
        "group_execution_requirements": attr.string_list_dict(default = {}),
        "group_compress_levels": attr.string_dict(default = {}),
        "warn_remote_cache_threshold_mb": attr.int(default = 200),
        "warn_layer_count": attr.int(default = 90),
        "platform": attr.string(default = ""),
        "layer_tier": attr.label(default = None, providers = [PyLayerTierInfo]),
        "_layer_tier": attr.label(
            default = "//py:layer_tier",
            providers = [PyLayerTierInfo],
        ),
        "_validator": attr.label(
            default = "//py/private:py_image_layer_validator",
            executable = True,
            cfg = "exec",
            allow_files = True,
        ),
        "_awk_script": attr.label(
            default = "//py/private:modify_mtree.awk",
            allow_single_file = True,
        ),
        "_awk": attr.label(
            default = "@gawk",
            cfg = "exec",
            executable = True,
        ),
    },
    cfg = _platform_cfg,
    toolchains = [_TAR_TOOLCHAIN],
)

def py_image_layer(
        name,
        binary,
        groups = {},
        group_execution_requirements = {},
        group_compress_levels = {},
        warn_remote_cache_threshold_mb = 200,
        warn_layer_count = 90,
        platform = None,
        layer_tier = None,
        **kwargs):
    """Create OCI-compatible tars from a py_binary or py_venv target.

    Pip-package grouping + compression is resolved from the `//py:layer_tier`
    label_flag. Override globally with `--//py:layer_tier=//path:custom_tier`,
    or pin a tier to a specific rule via the `py_layer_tier` attr below.

    ## Output layers

      1. Non-pip deps listed in `groups` → one rule-created tar per group.
      2. First-party py_library targets matched by `py_layer_tier.groups` → one
         rule-created tar per group (aggregated across all matched targets in the
         binary's dep closure).
      3. Solo-group and subpath-split pip tars — built by `_layer_aspect` at each pip
         target's own namespace; globally shared across every rule using that package.
      4. Multi-member merged tars — one per group, built by `_merge_aspect` at the
         binary's namespace from the closure-filtered union of member install_dirs.
      5. Ungrouped pip packages and generated venv dependency overlays → one
         squashed rule-created tar.
      6. Remaining first-party Python source files → the "default" layer.

    Args:
        name: Name of the generated target.
        binary: A py_venv or py_binary target.
        groups: Maps a NON-PIP dep label to a group name. Each gets its own rule-created
            tar. All pip-package grouping (whole-package, subpath, multi-member) belongs
            in py_layer_tier — subpath glob keys passed here fail loudly.
        group_execution_requirements: Maps a group name to execution requirement strings.
            The group name "packages" applies to the squashed ungrouped-pip tar.
        group_compress_levels: Maps a group name to a gzip compression level (1-9) for
            rule-created tars (non-pip deps, squashed ungrouped pip tar, source). Default 6.
            Does NOT apply to aspect-created pip tars (configure via the py_layer_tier target).
        warn_remote_cache_threshold_mb: Threshold for large package warnings.
        warn_layer_count: Warn when total layers exceed this. Default: 90.
        platform: Platform transition target.
        layer_tier: Optional py_layer_tier target pinned for this rule. Sets the
            `@aspect_rules_py//py:layer_tier` label_flag via the rule transition,
            overriding any command-line value for this rule's subgraph.
        **kwargs: Forwarded to inner rule.
    """
    tags = kwargs.pop("tags", []) + ["manual"]

    for key in groups:
        if _split_glob_key(key)[1] != None:
            fail(
                "py_image_layer.groups no longer supports subpath (glob) keys like %r. " % key +
                "Move pip subpath grouping to py_layer_tier(groups = {...}) — the same dict accepts label:glob keys.",
            )

    _py_image_layer(
        name = name,
        binary = binary,
        groups = groups,
        group_execution_requirements = group_execution_requirements,
        group_compress_levels = group_compress_levels,
        warn_remote_cache_threshold_mb = warn_remote_cache_threshold_mb,
        warn_layer_count = warn_layer_count,
        platform = platform or "",
        layer_tier = layer_tier,
        tags = tags,
        **kwargs
    )

    native.filegroup(
        name = name + "_no_src",
        srcs = [name],
        output_group = "deps",
        tags = tags,
    )
    native.filegroup(
        name = name + "_only_src",
        srcs = [name],
        output_group = "sources",
        tags = tags,
    )
