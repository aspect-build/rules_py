"""py_image_layer — analysis-time grouped OCI layers with globally shared pip tars.

Two rule-propagated aspects wire onto `py_image_layer.binary`:

  1. `_layer_aspect` — propagates through `deps`/`data`/`actual`. For pip packages it
     creates aspect-owned per-package tars at the pip target's namespace (globally
     shared across every rule using that package) for solo whole-groups and subpath
     splits. Members of multi-member whole groups get NO per-package tar — intermediate
     elided; they just flag `merge_group` on their _LayerInfo struct. Produces `_LayerInfo`.

  2. `_merge_aspect` — runs only on the binary (`attr_aspects = []`), after `_layer_aspect`
     via `required_aspect_providers`. Reads `_LayerInfo.pip_packages` (full closure),
     buckets install_dirs by `merge_group`, and emits one bsdtar action per group from
     raw install_dirs — single pass, no intermediates, content exactly matches closure
     (no dep leak). Produces `_MergedLayerInfo` declared at the binary's output namespace.

Layer tier (groups + compression) is carried by the `layer_tier` rule which produces
`LayerTierInfo`. Aspects read it via a private `_layer_tier` attr whose default is
`//py:layer_tier` (a label_flag). Users switch tiers globally via
`--//py:layer_tier=//path:custom_tier`.

Sharing model:
  - Solo whole-group + subpath-split pip tars: action-shared across every rule using
    that package (declared at the pip target's namespace).
  - Multi-member merged tars: per-binary action, but deterministic content (canonical
    mtree, fixed bsdtar options) → remote CAS / OCI registry dedupe by digest.
  - Ungrouped pip packages: squashed by the rule into one per-rule tar.
"""

load("@rules_python//python:defs.bzl", "PyInfo")

_TAR_TOOLCHAIN = "@tar.bzl//tar/toolchain:type"

_WHL_INSTALL_PREFIX = "aspect_rules_py++uv+whl_install__"

def normalize_label(label_str):
    """Canonicalize an aspect_rules_py whl_install label to '@pip//<pkg>'.

    Strings that don't look like whl_install labels are returned unchanged. Users
    must provide group keys in the canonical '@pip//<pkg>' form to match.

    Args:
        label_str: A label string or Label.

    Returns:
        '@pip//<pkg>' for a recognized whl_install label; the input unchanged otherwise.
    """
    label_str = str(label_str)
    idx = label_str.find(_WHL_INSTALL_PREFIX)
    if idx >= 0:
        rest = label_str[idx + len(_WHL_INSTALL_PREFIX):].split("//", 1)[0]
        parts = rest.split("__")
        if len(parts) >= 2:
            return "@pip//" + parts[1]
    return label_str

LayerTierInfo = provider(
    doc = "Layer tier for py_image_layer: how pip packages are grouped and compressed.",
    fields = {
        "whole_groups": "dict[str, str] — normalized pip label → group name.",
        "subpath_groups": "dict[str, dict[str, list[str]]] — label → {group_name: [glob_patterns]}.",
        "compression": "dict[str, list[str]] — normalized pip label → [algorithm, level].",
        "multi_member_groups": "dict[str, True] — group names with 2+ members in whole_groups.",
    },
)

def _split_glob_key(key):
    """If key is '@pip//pkg:glob', return (label, pattern); else return (None, None)."""
    colon_idx = key.rfind(":")
    if colon_idx > 0 and ("*" in key[colon_idx:] or "?" in key[colon_idx:]):
        return key[:colon_idx], key[colon_idx + 1:]
    return None, None

def _layer_tier_impl(ctx):
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

    return [LayerTierInfo(
        whole_groups = whole_groups,
        subpath_groups = subpath_groups,
        compression = {normalize_label(k): v for k, v in ctx.attr.compression.items()},
        multi_member_groups = multi_member_groups,
    )]

layer_tier = rule(
    implementation = _layer_tier_impl,
    attrs = {
        "groups": attr.string_dict(
            default = {},
            doc = ("Maps @pip//package → group name (whole package) or " +
                   "@pip//package:glob → group name (subpath split)."),
        ),
        "compression": attr.string_list_dict(
            default = {},
            doc = "Maps @pip//package → [algorithm, level], e.g. {\"@pip//torch\": [\"zstd\", \"1\"]}.",
        ),
    },
    provides = [LayerTierInfo],
)

_LayerInfo = provider(
    doc = "Private: aggregated source files + pip package layers produced by _layer_aspect.",
    fields = {
        "source_files": "depset[File] — first-party Python source files.",
        "pip_packages": "depset[struct] — fully transitive pip packages with per-package layers.",
        "transitive_pip_count": "int — 1 + sum of pip deps' counts; propagation field.",
    },
)

_PY_VENV_KINDS = ("py_venv", "_py_venv")

_PY_BINARY_KINDS = ("py_binary", "py_test", "_py_venv_binary", "_py_venv_test", "py_venv_binary", "py_venv_test")

def _collect_from_deps(ctx, provider):
    """Walk deps/data/actual and return a list of provider values from each matching dep."""
    results = []
    for attr_name in ["deps", "data"]:
        for dep in getattr(ctx.rule.attr, attr_name, []):
            if provider in dep:
                results.append(dep[provider])
    actual = getattr(ctx.rule.attr, "actual", None)
    if actual != None and type(actual) != "list":
        if provider in actual:
            results.append(actual[provider])
    elif actual:
        for dep in actual:
            if provider in dep:
                results.append(dep[provider])
    return results

def _compression_ext(algorithm):
    return ".tar.zst" if algorithm == "zstd" else ".tar.gz"

def _build_pip_layers(ctx, plan, label, install_dir):
    """Create aspect-owned tars for a pip package; decide whether to defer to _merge_aspect.

    Returns (layers, merge_group):
      - layers: tuple of struct(tar, group). Per-package tars at the pip target's namespace,
        globally shared across every rule that depends on this package.
      - merge_group: str | None. Set when this package is deferred to _merge_aspect (member
        of a multi-member whole-group, no per-package tar created); None otherwise.
    """
    subpath_for_this = plan.subpath_groups.get(label, {})
    whole_group = plan.whole_groups.get(label, None)
    is_multi_member = whole_group != None and whole_group in plan.multi_member_groups

    if is_multi_member and subpath_for_this:
        fail(("layer_tier bug for %s: package is a member of multi-member group %r and " +
              "also has subpath_groups. A pip package may be in a multi-member group OR " +
              "have subpath splits, not both.") % (label, whole_group))

    if is_multi_member:
        return ((), whole_group)

    if not subpath_for_this and whole_group == None:
        return ((), None)

    toolchain = ctx.toolchains[_TAR_TOOLCHAIN]
    bsdtar = toolchain.tarinfo
    bsdtar_files = toolchain.default

    comp = plan.compression.get(label, None)
    algorithm = comp[0] if comp else "gzip"
    level = comp[1] if comp else "6"
    ext = _compression_ext(algorithm)

    layers = []

    if subpath_for_this:
        all_patterns = [p for pats in subpath_for_this.values() for p in pats]
        for grp_name, patterns in subpath_for_this.items():
            tar_out = ctx.actions.declare_file("_pip_layer_{}{}".format(grp_name, ext))
            _run_tar_action(
                ctx,
                bsdtar,
                bsdtar_files,
                tar_out,
                install_dir,
                _make_pattern_map_each(patterns),
                algorithm,
                level,
                {},
                "PyImagePkgLayer",
                "Creating pip layer %s[%s]" % (label, grp_name),
            )
            layers.append(struct(tar = tar_out, group = grp_name))

        rest_tar = ctx.actions.declare_file("_pip_layer_tar" + ext)
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            rest_tar,
            install_dir,
            _make_rest_map_each(all_patterns),
            algorithm,
            level,
            {},
            "PyImagePkgLayer",
            "Creating pip layer %s[rest]" % label,
        )
        layers.append(struct(tar = rest_tar, group = whole_group))
    else:
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
    dep_infos = _collect_from_deps(ctx, _LayerInfo)
    transitive_source = [info.source_files for info in dep_infos]
    transitive_pkgs = [info.pip_packages for info in dep_infos]
    pip_count = 0
    for info in dep_infos:
        pip_count += info.transitive_pip_count

    if OutputGroupInfo in target and hasattr(target[OutputGroupInfo], "install_dir"):
        plan = ctx.attr._layer_tier[LayerTierInfo]
        label = normalize_label(str(target.label))
        install_dir = target[OutputGroupInfo].install_dir
        pkg_pip_count = 1 + pip_count
        layers, merge_group = _build_pip_layers(ctx, plan, label, install_dir)

        return [_LayerInfo(
            source_files = depset(transitive = transitive_source),
            pip_packages = depset(
                direct = [struct(
                    label = label,
                    files = install_dir,
                    layers = layers,
                    merge_group = merge_group,
                    transitive_pip_count = pkg_pip_count,
                )],
                transitive = transitive_pkgs,
            ),
            transitive_pip_count = pkg_pip_count,
        )]

    own_source = []
    kind = ctx.rule.kind
    if kind not in _PY_VENV_KINDS and PyInfo in target:
        own_source.append(target[DefaultInfo].files)

    # Binary rules are the image's entry point. Capture the full runfiles tree so
    # the interpreter + venv directory land in the image (py_venv_binary assembles
    # its site-packages as a tree artifact in runfiles; the interpreter is toolchain
    # runfiles). Pip install_dirs are filtered out here because they already ship in
    # their own pip layers; OCI layer overlay would otherwise duplicate the bytes.
    if kind in _PY_BINARY_KINDS:
        if PyInfo not in target:
            own_source.append(target[DefaultInfo].files)
        pip_paths = {}
        for pkg_depset in transitive_pkgs:
            for pkg in pkg_depset.to_list():
                for f in pkg.files.to_list():
                    pip_paths[f.path] = True
        runfiles_files = target[DefaultInfo].default_runfiles.files.to_list()
        filtered = [f for f in runfiles_files if f.path not in pip_paths]
        if filtered:
            own_source.append(depset(direct = filtered))

    return [_LayerInfo(
        source_files = depset(transitive = transitive_source + own_source),
        pip_packages = depset(transitive = transitive_pkgs),
        transitive_pip_count = pip_count,
    )]

_layer_aspect = aspect(
    implementation = _layer_aspect_impl,
    attr_aspects = ["deps", "data", "actual"],
    attrs = {
        "_layer_tier": attr.label(
            default = "//py:layer_tier",
            providers = [LayerTierInfo],
        ),
    },
    toolchains = [_TAR_TOOLCHAIN],
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

    toolchain = ctx.toolchains[_TAR_TOOLCHAIN]
    bsdtar = toolchain.tarinfo
    bsdtar_files = toolchain.default

    merged_tars = {}
    for group_name in sorted(bucket):
        install_dirs = bucket[group_name]
        tar_out = ctx.actions.declare_file("_merged_pip_layer_{}.tar.gz".format(group_name))
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            tar_out,
            depset(transitive = install_dirs),
            _pkg_file_to_mtree,
            "gzip",
            "6",
            {},
            "PyImageMergedLayer",
            "Merging %d pip packages into %s[%s]" % (len(install_dirs), target.label, group_name),
        )
        merged_tars[group_name] = tar_out

    return [_MergedLayerInfo(merged_tars = merged_tars)]

_merge_aspect = aspect(
    implementation = _merge_aspect_impl,
    attr_aspects = [],
    toolchains = [_TAR_TOOLCHAIN],
    required_aspect_providers = [[_LayerInfo]],
    provides = [_MergedLayerInfo],
)

def _file_to_mtree_entry(f, mode = "0644", strip_prefix = "", root = "/"):
    sp = f.short_path
    if sp.startswith("../"):
        dst = "./app.runfiles/" + sp[3:]
    elif strip_prefix:
        prefix = strip_prefix.replace("\\/", "/")
        if sp == prefix:
            dst = "." + root
        elif sp.startswith(prefix + "."):
            dst = "." + root + sp[len(prefix):]
        else:
            dst = "./app.runfiles/_main/" + sp
    else:
        dst = "./app.runfiles/_main/" + sp
    return "{} type=file mode={} uid=0 gid=0 time=1672560000 contents={}".format(
        dst.replace(" ", "\\040"),
        mode,
        f.path.replace(" ", "\\040"),
    )

def _source_file_to_mtree(f, dir_expander, strip_prefix, root):
    # Use 0755 throughout so the binary launcher, the interpreter, and venv shims
    # remain executable when unpacked. Setting the exec bit on .py/.txt as well is
    # harmless and keeps the mtree logic simple — we'd otherwise need to carry each
    # input file's source mode through the aspect, which Bazel doesn't expose.
    if f.is_directory:
        return [
            _file_to_mtree_entry(child, "0755", strip_prefix, root)
            for child in dir_expander.expand(f)
        ]
    return _file_to_mtree_entry(f, "0755", strip_prefix, root)

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

def _make_pattern_map_each(patterns):
    def _fn(f, dir_expander):
        if f.is_directory:
            lines = []
            for child in dir_expander.expand(f):
                p = child.path
                if _should_skip_pkg_path(p):
                    continue
                if any([_glob_match(p, pat) for pat in patterns]):
                    lines.append(_file_to_mtree_entry(child, "0755"))
            return lines
        if any([_glob_match(f.path, pat) for pat in patterns]):
            return [_file_to_mtree_entry(f, "0755")]
        return []

    return _fn

def _make_rest_map_each(all_patterns):
    def _fn(f, dir_expander):
        if f.is_directory:
            lines = []
            for child in dir_expander.expand(f):
                p = child.path
                if _should_skip_pkg_path(p):
                    continue
                if not any([_glob_match(p, pat) for pat in all_patterns]):
                    lines.append(_file_to_mtree_entry(child, "0755"))
            return lines
        if not any([_glob_match(f.path, pat) for pat in all_patterns]):
            return [_file_to_mtree_entry(f, "0755")]
        return []

    return _fn

def _parse_exec_requirements(entries):
    reqs = {}
    for entry in entries:
        k, _, v = entry.partition("=")
        reqs[k] = v
    return reqs

def _platform_cfg_impl(_settings, attr):
    if attr.platform:
        return {"//command_line_option:platforms": [attr.platform]}
    return {}

_platform_cfg = transition(
    implementation = _platform_cfg_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _run_tar_action(ctx, bsdtar, bsdtar_files, tar_out, files_depset, map_each, compress, level, reqs, mnemonic, progress_msg):
    bsdtar_args = ctx.actions.args()
    bsdtar_args.add("--create")
    bsdtar_args.add("--" + compress)
    bsdtar_args.add("--options", "{}:compression-level={}".format(compress, level))
    bsdtar_args.add("--file", tar_out)

    mtree_args = ctx.actions.args()
    mtree_args.set_param_file_format("multiline")
    mtree_args.use_param_file("@%s", use_always = True)
    mtree_args.add("#mtree")
    mtree_args.add_all(files_depset, map_each = map_each, expand_directories = False, allow_closure = True)

    ctx.actions.run(
        executable = bsdtar.binary,
        inputs = depset(transitive = [files_depset, bsdtar_files.files]),
        outputs = [tar_out],
        arguments = [bsdtar_args, mtree_args],
        mnemonic = mnemonic,
        progress_message = progress_msg,
        execution_requirements = reqs,
        toolchain = _TAR_TOOLCHAIN,
    )

def _py_image_layer_impl(ctx):
    info = ctx.attr.binary[_LayerInfo]
    merged = ctx.attr.binary[_MergedLayerInfo]
    toolchain = ctx.toolchains[_TAR_TOOLCHAIN]
    bsdtar = toolchain.tarinfo
    bsdtar_files = toolchain.default

    seen_labels = {}
    all_pkgs = []
    for pkg in info.pip_packages.to_list():
        if pkg.label not in seen_labels:
            seen_labels[pkg.label] = True
            all_pkgs.append(pkg)

    pkg_by_label = {pkg.label: pkg for pkg in all_pkgs}

    strip_prefix = ctx.attr.strip_prefix
    root = ctx.attr.root

    all_tars = []
    dep_tars = []

    # ── 1. Non-pip deps assigned via rule groups= ───────────────────────────
    for dep, group_name in ctx.attr.groups.items():
        dep_label = normalize_label(str(dep.label))
        if dep_label in pkg_by_label:
            continue
        level = ctx.attr.group_compress_levels.get(group_name, "6")
        reqs = _parse_exec_requirements(
            ctx.attr.group_execution_requirements.get(group_name, []),
        )
        tar_out = ctx.actions.declare_file("{}_{}.tar.gz".format(ctx.attr.name, group_name))
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            tar_out,
            dep[DefaultInfo].files,
            _user_file_to_mtree,
            "gzip",
            level,
            reqs,
            "PyImageLayer",
            "Creating image layer %s[%s]" % (ctx.label, group_name),
        )
        all_tars.append(tar_out)
        dep_tars.append(tar_out)

    # ── 2. Grouped pip packages — aspect-owned tars from _layer_aspect ─────
    for pkg in all_pkgs:
        for layer in pkg.layers:
            all_tars.append(layer.tar)
            dep_tars.append(layer.tar)

    # ── 3. Multi-member merged tars from _merge_aspect ──────────────────────
    for group_name, merged_tar in sorted(merged.merged_tars.items()):
        all_tars.append(merged_tar)
        dep_tars.append(merged_tar)

    # ── 4. Ungrouped pip packages — squashed into a single tar ──────────────
    ungrouped_pkgs = [p for p in all_pkgs if len(p.layers) == 0 and p.merge_group == None]
    if ungrouped_pkgs:
        squashed_tar = ctx.actions.declare_file("{}_squashed.tar.gz".format(ctx.attr.name))
        squashed_level = ctx.attr.group_compress_levels.get("packages", "6")
        squashed_reqs = _parse_exec_requirements(
            ctx.attr.group_execution_requirements.get("packages", []),
        )
        squashed_files = depset(transitive = [p.files for p in ungrouped_pkgs])
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            squashed_tar,
            squashed_files,
            _pkg_file_to_mtree,
            "gzip",
            squashed_level,
            squashed_reqs,
            "PyImageLayer",
            "Creating squashed pip layer (%d ungrouped packages) for %s" % (
                len(ungrouped_pkgs),
                ctx.label,
            ),
        )
        all_tars.append(squashed_tar)
        dep_tars.append(squashed_tar)

    # ── 5. Source layer ──────────────────────────────────────────────────────
    source_tar = ctx.actions.declare_file("{}_default.tar.gz".format(ctx.attr.name))
    source_level = ctx.attr.group_compress_levels.get("default", "6")
    source_reqs = _parse_exec_requirements(
        ctx.attr.group_execution_requirements.get("default", []),
    )

    def _source_map(f, d):
        return _source_file_to_mtree(f, d, strip_prefix, root)

    _run_tar_action(
        ctx,
        bsdtar,
        bsdtar_files,
        source_tar,
        info.source_files,
        _source_map,
        "gzip",
        source_level,
        source_reqs,
        "PyImageLayer",
        "Creating source layer for %s" % ctx.label,
    )
    all_tars.append(source_tar)

    # ── Validation ───────────────────────────────────────────────────────────
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
        "root": attr.string(default = "/"),
        "strip_prefix": attr.string(default = ""),
        "platform": attr.string(default = ""),
        "_validator": attr.label(
            default = "//py/private:py_image_layer_validator",
            executable = True,
            cfg = "exec",
            allow_files = True,
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
        root = "/",
        strip_prefix = "",
        platform = None,
        **kwargs):
    """Create OCI-compatible tars from a py_binary or py_venv target.

    Pip-package grouping + compression is resolved from the `//py:layer_tier`
    label_flag. Override globally with `--//py:layer_tier=//path:custom_tier`.

    ## Output layers

      1. Non-pip deps listed in `groups` → one rule-created tar per group.
      2. Solo-group and subpath-split pip tars — built by `_layer_aspect` at each pip
         target's own namespace; globally shared across every rule using that package.
      3. Multi-member merged tars — one per group, built by `_merge_aspect` at the
         binary's namespace from the closure-filtered union of member install_dirs.
      4. Ungrouped pip packages → one squashed rule-created tar.
      5. First-party Python source files → the "default" layer.

    Args:
        name: Name of the generated target.
        binary: A py_venv or py_binary target.
        groups: Maps a NON-PIP dep label to a group name. Each gets its own rule-created
            tar. All pip-package grouping (whole-package, subpath, multi-member) belongs
            in layer_tier — subpath glob keys passed here fail loudly.
        group_execution_requirements: Maps a group name to execution requirement strings.
            The group name "packages" applies to the squashed ungrouped-pip tar.
        group_compress_levels: Maps a group name to a gzip compression level (1-9) for
            rule-created tars (non-pip deps, squashed ungrouped pip tar, source). Default 6.
            Does NOT apply to aspect-created pip tars (configure via the layer_tier target).
        warn_remote_cache_threshold_mb: Threshold for large package warnings.
        warn_layer_count: Warn when total layers exceed this. Default: 90.
        root: Root path in image. Default: "/".
        strip_prefix: Prefix stripped from source file paths.
        platform: Platform transition target.
        **kwargs: Forwarded to inner rule.
    """
    tags = kwargs.pop("tags", []) + ["manual"]

    for key in groups:
        if _split_glob_key(key)[1] != None:
            fail(
                "py_image_layer.groups no longer supports subpath (glob) keys like %r. " % key +
                "Move pip subpath grouping to layer_tier(groups = {...}).",
            )

    _py_image_layer(
        name = name,
        binary = binary,
        groups = groups,
        group_execution_requirements = group_execution_requirements,
        group_compress_levels = group_compress_levels,
        warn_remote_cache_threshold_mb = warn_remote_cache_threshold_mb,
        warn_layer_count = warn_layer_count,
        root = root,
        strip_prefix = strip_prefix,
        platform = platform or "",
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
