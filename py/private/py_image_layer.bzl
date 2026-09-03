"""py_image_layer — analysis-time grouped OCI layers with globally shared pip tars.

`_layer_aspect` and `_merge_aspect` wire onto each `py_image_layer` binary.
Single-binary images reuse action-shared merged pip layers.

`_layer_aspect` propagates through `deps`/`data`/`actual`. For pip packages it
creates aspect-owned per-package tars at the pip target's namespace (globally
shared across every rule using that package) for solo whole-groups and subpath
splits. Members of multi-member whole groups get NO per-package tar — intermediate
elided; they just flag `merge_group` on their _LayerInfo struct. First-party
PyInfo targets matched by `py_layer_tier.groups` are captured as `first_party_layers`
entries (label, files, group) for the image-layer rule. Produces `_LayerInfo`.

Layer tier (groups + compression) is carried by the `py_layer_tier` rule which produces
`PyLayerTierInfo`. Aspects read it via a private `_layer_tier` attr whose default is
`//py:layer_tier` (a label_flag). Users switch tiers globally via
`--//py:layer_tier=//path:custom_tier`.

That private attr is why a tier can never be testonly: the aspect attaches it to every
target it visits, including non-testonly ones outside the image (interpreter toolchain,
third-party installs). `_py_layer_tier_impl` rejects it up front.

Sharing model:
  - Solo whole-group + subpath-split pip tars: action-shared across every rule using
    that package (declared at the pip target's namespace).
  - Multi-member merged tars: action-shared for a single binary; one unioned
    per-rule action for multiple binaries, with deterministic content.
  - First-party grouped tars: per-rule action, one tar per group, collected from
    matched py_library targets in the binaries' dep closures.
  - Ungrouped pip packages: squashed by the rule into one per-rule tar.
"""

load(
    "//py/private:compression.bzl",
    "DEFAULT_ALGORITHM",
    "DEFAULT_LEVEL",
    "PyLayerCompressorInfo",
    "check_oci_compatible",
    "codec_from_compressor",
    "codec_tar_args",
    "codec_tools",
    "make_codec",
    "parse_compression",
)
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:py_info_interop.bzl", "has_py_info")
load("//py/private/py_venv:types.bzl", "VirtualenvInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "interpreter_files_and_version")

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
        "compression": "dict[str, list[str]] — group name → [algorithm, level], as written on the rule.",
        "compressors": "dict[str, PyLayerCompressorInfo] — group name → custom compressor.",
        "codecs": "dict[str, struct] — group name → resolved codec (bsdtar flags + file extension).",
        "multi_member_groups": "dict[str, True] — group names with 2+ members in whole_groups.",
        "interpreter_group": "str — group name for the Python interpreter layer; '' disables.",
        "root": "str — root path in the image (e.g. '/app').",
        "strip_prefix": "str — prefix stripped from source file paths; empty means use binary short_path.",
        "owner": "str — numeric uid owning files in the layer.",
        "group": "str — numeric gid owning files in the layer.",
    },
)

def _split_glob_key(key):
    """If key is '@pip//pkg:glob', return (label, pattern); else return (None, None)."""
    colon_idx = key.rfind(":")
    if colon_idx > 0 and ("*" in key[colon_idx:] or "?" in key[colon_idx:]):
        return key[:colon_idx], key[colon_idx + 1:]
    return None, None

def _validate_numeric_id(value, attr_name):
    # mtree's uid=/gid= fields only accept numbers; a name would produce an
    # unparseable archive at tar time rather than an analysis error.
    if not value.isdigit():
        fail("py_layer_tier.%s must be a numeric id, got %r" % (attr_name, value))

def _py_layer_tier_impl(ctx):
    if ctx.attr.testonly:
        fail("py_layer_tier targets cannot be testonly: py_image_layer transitions " +
             "//py:layer_tier to this target, and the layer aspect reads it from " +
             "non-testonly targets in the binary's closure. Set testonly = False " +
             "(explicitly, under package(default_testonly = True)).")

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

    _validate_numeric_id(ctx.attr.owner, "owner")
    _validate_numeric_id(ctx.attr.group, "group")

    codecs = {}
    for group_name, value in ctx.attr.compression.items():
        codec = parse_compression(value, "py_layer_tier.compression[%r]" % group_name)
        check_oci_compatible(codec, group_name, "py_layer_tier.compression", ctx.attr.allow_non_oci_layers)
        codecs[group_name] = codec

    compressors = {}
    seen = {}
    for dep, group_name in ctx.attr.compressors.items():
        # Duplicates first: the group is already in `codecs` by then, so the
        # `compression` check below would otherwise claim the wrong conflict.
        if group_name in seen:
            fail(("group %r is mapped to two py_layer_compressor targets (%s and %s) in " +
                  "py_layer_tier.compressors. A group gets its bytes from exactly one " +
                  "compressor.") % (group_name, seen[group_name], dep.label))
        if group_name in codecs:
            fail(("group %r is configured in both py_layer_tier.compression and " +
                  "py_layer_tier.compressors. A group gets its bytes from exactly one " +
                  "compressor — drop one of the two entries.") % group_name)
        seen[group_name] = dep.label
        info = dep[PyLayerCompressorInfo]
        compressors[group_name] = info
        codec = codec_from_compressor(info)
        check_oci_compatible(codec, group_name, "py_layer_tier.compressors", ctx.attr.allow_non_oci_layers)
        codecs[group_name] = codec

    return [PyLayerTierInfo(
        whole_groups = whole_groups,
        subpath_groups = subpath_groups,
        compression = dict(ctx.attr.compression),
        compressors = compressors,
        codecs = codecs,
        multi_member_groups = multi_member_groups,
        interpreter_group = ctx.attr.interpreter_group,
        root = ctx.attr.root,
        strip_prefix = ctx.attr.strip_prefix,
        owner = ctx.attr.owner,
        group = ctx.attr.group,
    )]

py_layer_tier = rule(
    implementation = _py_layer_tier_impl,
    doc = ("Grouping and compression plan for `py_image_layer`.\n\n" +
           "Must not be testonly. `py_image_layer` transitions the `//py:layer_tier` " +
           "flag to the tier, and the layer aspect reads that flag from every target it " +
           "visits — including non-testonly ones outside the image, such as the interpreter " +
           "toolchain and third-party installs. In a `package(default_testonly = True)`, " +
           "set `testonly = False` on the tier."),
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
            doc = ("Maps group name → [algorithm] or [algorithm, level]. Applies to every " +
                   "layer this tier names: the whole-group tar, each subpath-split tar, the " +
                   "multi-member merged tar, the interpreter tar, and first-party group tars.\n\n" +
                   "`algorithm` is any bsdtar (libarchive) write filter: `none`, `gzip`, " +
                   "`bzip2`, `xz`, `lzma`, `lzop`, `lz4`, `lrzip`, `zstd`, or `compress`. " +
                   "`lzop` and `lrzip` shell out to a same-named binary that must exist inside " +
                   "the action — use `compressors` for a hermetic equivalent. `none` and " +
                   "`compress` take no level.\n\n" +
                   "`level` is optional; omit it to take libarchive's default for that filter. " +
                   "Example: {\"heavy_pkgs\": [\"zstd\", \"19\"], \"cold\": [\"xz\"]}. " +
                   "Untouched groups default to gzip -6."),
        ),
        "compressors": attr.label_keyed_string_dict(
            default = {},
            cfg = "exec",
            providers = [PyLayerCompressorInfo],
            doc = ("Maps a `py_layer_compressor` target → group name, for compressors libarchive " +
                   "has no filter for. bsdtar pipes the layer through the program. A group " +
                   "may appear here or in `compression`, not both."),
        ),
        "allow_non_oci_layers": attr.bool(
            default = False,
            doc = ("Permit compression the OCI image spec has no layer format for. " +
                   "The spec defines only tar, gzip and zstd; rules_oci labels anything " +
                   "else an uncompressed tar and records the compressed digest as the " +
                   "layer's diffid, so the image is invalid even though the build " +
                   "succeeds. Set this only when the tars are consumed by something " +
                   "other than an OCI image."),
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
        "owner": attr.string(
            default = "0",
            doc = "Numeric uid owning every file in every layer this tier produces. Default: '0' (root).",
        ),
        "group": attr.string(
            default = "0",
            doc = "Numeric gid owning every file in every layer this tier produces. Default: '0' (root).",
        ),
    },
    provides = [PyLayerTierInfo],
)

_LayerInfo = provider(
    doc = "Private: aggregated source files + pip package layers produced by _layer_aspect.",
    fields = {
        "source_files": "depset[File] — default source layer candidates, collected from venv providers, binary outputs, and opaque runtime deps; bytes owned by other layers are dropped by the source tar's skip set.",
        "pip_packages": "depset[struct] — fully transitive pip packages with per-package layers.",
        "first_party_layers": "depset[struct(label, files, group)] — first-party PyInfo targets matched by py_layer_tier.groups.",
        "interpreter_layer": "struct(tar, group, interpreter_files) | None — prebuilt interpreter layer tar + its group name + the files used to build it, declared at the toolchain target's namespace so the tar action-shares across every py_image_layer using that toolchain config. tar=None at the toolchain node when no interpreter group is configured.",
    },
)

def _terminal_venv(ctx):
    """The launcher's sibling venv Target; its transitioned label attr may present as a single-element list."""
    value = getattr(ctx.rule.attr, "venv", None)
    if type(value) == "list":
        return value[0] if len(value) == 1 else None
    return value

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
    venv = _terminal_venv(ctx)
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
    for dep in getattr(ctx.rule.attr, "resolutions", {}).values():
        if provider in dep:
            results.append(dep[provider])
    return results

def _runtime_files(dep):
    """Return an opaque runtime target's outputs plus its transitive runfiles."""
    return depset(transitive = [
        dep[DefaultInfo].files,
        dep[DefaultInfo].default_runfiles.files,
    ])

def _opaque_dep_files(rule_attr, attr_names):
    # PyInfo deps (including wheel leaves) self-capture via the aspect.
    parts = []
    for attr_name in attr_names:
        for dep in getattr(rule_attr, attr_name, None) or []:
            if not has_py_info(dep) and DefaultInfo in dep:
                parts.append(_runtime_files(dep))
    return parts

_DEFAULT_CODEC = make_codec(DEFAULT_ALGORITHM, DEFAULT_LEVEL)

def _codec_for(plan, group_name):
    """Codec for a tier-named group; gzip -6 for groups the tier never mentions."""
    if not group_name:
        return _DEFAULT_CODEC
    return plan.codecs.get(group_name, _DEFAULT_CODEC)

def _tar_toolchain(ctx):
    tc = ctx.toolchains[_TAR_TOOLCHAIN]
    return tc.tarinfo, tc.default

def _build_pip_layers(ctx, plan, label, install_dir):
    """Declare per-package pip tars for one wheel target.

    Returns (layers, merge_group): layers is a tuple of struct(tar, group)
    entries for this package; merge_group is set (and layers is empty) iff
    the package is deferred for closure-level merging.
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
    pkg_map = lambda f, d: _pkg_file_to_mtree(f, d, plan.owner, plan.group)

    if subpath_for_this:
        all_patterns = [p for pats in subpath_for_this.values() for p in pats]
        for grp_name, patterns in subpath_for_this.items():
            codec = _codec_for(plan, grp_name)
            tar_out = ctx.actions.declare_file("_pip_layer_{}{}".format(grp_name, codec.ext))
            _run_tar_action(
                ctx,
                bsdtar,
                bsdtar_files,
                tar_out,
                install_dir,
                _make_glob_map_each(patterns, plan.owner, plan.group),
                codec,
                {},
                "PyImagePkgLayer",
                "Creating pip layer %s[%s]" % (label, grp_name),
            )
            layers.append(struct(tar = tar_out, group = grp_name))

        codec = _codec_for(plan, whole_group)
        rest_tar = ctx.actions.declare_file("_pip_layer_tar" + codec.ext)
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            rest_tar,
            install_dir,
            _make_glob_map_each(all_patterns, plan.owner, plan.group, invert = True),
            codec,
            {},
            "PyImagePkgLayer",
            "Creating pip layer %s[rest]" % label,
        )
        layers.append(struct(tar = rest_tar, group = whole_group))
    else:
        codec = _codec_for(plan, whole_group)
        tar_out = ctx.actions.declare_file("_pip_layer_tar" + codec.ext)
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            tar_out,
            install_dir,
            pkg_map,
            codec,
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
        interp_depset, _ = interpreter_files_and_version(target)
        if interp_depset == None:
            return []
        plan = ctx.attr._layer_tier[PyLayerTierInfo]
        interp_group = plan.interpreter_group

        # tar=None: no interpreter layer configured; files go to the source layer.
        interp_layer = struct(tar = None, group = None, interpreter_files = interp_depset)
        if interp_group:
            bsdtar, bsdtar_files = _tar_toolchain(ctx)
            codec = _codec_for(plan, interp_group)
            interp_tar = ctx.actions.declare_file("_interpreter_layer_{}{}".format(interp_group, codec.ext))
            _run_tar_action(
                ctx,
                bsdtar,
                bsdtar_files,
                interp_tar,
                interp_depset,
                lambda f, d: _interpreter_file_to_mtree(f, d, plan.owner, plan.group),
                codec,
                {},
                "PyImagePkgLayer",
                "Creating interpreter layer %s" % target.label,
            )
            interp_layer = struct(tar = interp_tar, group = interp_group, interpreter_files = interp_depset)
        return [_LayerInfo(
            source_files = depset(),
            pip_packages = depset(),
            first_party_layers = depset(),
            interpreter_layer = interp_layer,
        )]

    dep_infos = _collect_from_deps(ctx, _LayerInfo)
    transitive_source = [info.source_files for info in dep_infos]
    transitive_pkgs = [info.pip_packages for info in dep_infos]
    transitive_fp = [info.first_party_layers for info in dep_infos]
    transitive_interp = [info.interpreter_layer for info in dep_infos if info.interpreter_layer != None]

    if PyWheelsInfo in target and ctx.rule.kind in ("whl_install", "py_unpacked_wheel"):
        plan = ctx.attr._layer_tier[PyLayerTierInfo]
        label = normalize_label(str(target.label))
        wheel_records = target[PyWheelsInfo].wheels.to_list()
        if len(wheel_records) != 1:
            fail("py_image_layer expected exactly one wheel record from {}, got {}".format(target.label, len(wheel_records)))
        wheel = wheel_records[0]
        install_dir = target[PyInfo].transitive_sources
        layers, merge_group = _build_pip_layers(ctx, plan, label, install_dir)

        return [_LayerInfo(
            source_files = depset(transitive = transitive_source),
            pip_packages = depset(
                direct = [struct(
                    artifact_key = wheel.install_tree,
                    label = label,
                    files = install_dir,
                    layers = layers,
                    merge_group = merge_group,
                )],
                transitive = transitive_pkgs,
            ),
            first_party_layers = depset(transitive = transitive_fp),
            interpreter_layer = None,
        )]

    own_source = []
    own_fp = []
    interpreter_layer = None
    kind = ctx.rule.kind

    # The binary being layered must be a rules_py py_binary (it carries rules_py's
    # PyInfo); rules_python's py_binary is not supported. rules_python *library*
    # deps within the graph are still handled by the membership checks below.
    is_binary = (
        PyInfo in target and
        target[DefaultInfo].files_to_run.executable != None
    )

    # Aliases (and other pure-forwarding wrappers) forward DefaultInfo from
    # `actual`. Reading `target[DefaultInfo].files` here for an alias of a
    # wheel target would re-introduce the install_tree as a source file — but
    # it is already captured upstream as a pip package via the wheel-leaf
    # branch. Just propagate transitively for these targets.
    if kind == "alias":
        interp = transitive_interp[0] if transitive_interp else None
        return [_LayerInfo(
            source_files = depset(transitive = transitive_source),
            pip_packages = depset(transitive = transitive_pkgs),
            first_party_layers = depset(transitive = transitive_fp),
            interpreter_layer = interp,
        )]

    if VirtualenvInfo not in target and has_py_info(target) and not is_binary:
        own_depset = depset(transitive = [target[DefaultInfo].files] + _opaque_dep_files(ctx.rule.attr, ("data", "deps")))

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

    if VirtualenvInfo in target:
        # Own srcs and opaque dep closures, not transitive_sources or runfiles:
        # wheel install trees must stay out of the source layer's inputs.
        own_source.append(target[VirtualenvInfo].runtime_files)
        own_source.append(depset(ctx.rule.files.srcs))
        own_source.extend(_opaque_dep_files(ctx.rule.attr, ("data", "deps")))
        if PY_TOOLCHAIN in ctx.rule.toolchains:
            py_tc = ctx.rule.toolchains[PY_TOOLCHAIN]
            if _LayerInfo in py_tc:
                tc_layer = py_tc[_LayerInfo].interpreter_layer
                if tc_layer.tar != None:
                    interpreter_layer = tc_layer
                else:
                    own_source.append(tc_layer.interpreter_files)

    # Venv sources arrive via the sibling venv's provider; the binary adds
    # only its own outputs and launcher-local opaque `data`.
    if is_binary:
        # The venv propagates the interpreter layer declared at its toolchain so
        # the binary uses the exact interpreter that built the venv.
        venv = _terminal_venv(ctx)
        if venv != None and _LayerInfo in venv:
            interpreter_layer = venv[_LayerInfo].interpreter_layer

        own_source.append(target[DefaultInfo].files)
        own_source.extend(_opaque_dep_files(ctx.rule.attr, ("data",)))

    return [_LayerInfo(
        source_files = depset(transitive = transitive_source + own_source),
        pip_packages = depset(transitive = transitive_pkgs),
        first_party_layers = depset(direct = own_fp, transitive = transitive_fp),
        interpreter_layer = interpreter_layer,
    )]

_layer_aspect = aspect(
    implementation = _layer_aspect_impl,
    attr_aspects = ["deps", "data", "actual", "venv", "resolutions"],
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
        codec = _codec_for(plan, group_name)
        tar_out = ctx.actions.declare_file("_merged_pip_layer_{}{}".format(group_name, codec.ext))
        _run_tar_action(
            ctx,
            bsdtar,
            bsdtar_files,
            tar_out,
            depset(transitive = install_dirs),
            lambda f, d: _pkg_file_to_mtree(f, d, plan.owner, plan.group),
            codec,
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
    """Destination for sp under the strip remap, or None when the prefix does not apply."""
    prefix = strip_prefix.replace("\\/", "/")
    if sp == prefix:
        return "." + root

    if sp.startswith(prefix + ".runfiles/") or sp.startswith(prefix + "/"):
        return "." + root + sp[len(prefix):]
    return None

def _source_destination(sp, strip_prefix, root, executable_dsts):
    executable_dst = executable_dsts.get(sp, None)
    if executable_dst:
        return executable_dst
    if sp == "_repo_mapping":
        # Bazel synthesizes a top-level `_repo_mapping` runfile (no `_main/`
        # prefix); replicate that placement so runfiles.bash can find it.
        return "./app.runfiles/_repo_mapping"
    runfiles_prefix = None
    for executable_short_path in executable_dsts:
        if (sp.startswith(executable_short_path + ".runfiles/") or
            (not strip_prefix and not executable_dsts[executable_short_path] and sp.startswith(executable_short_path + "/"))):
            if runfiles_prefix == None or len(executable_short_path) > len(runfiles_prefix):
                runfiles_prefix = executable_short_path
    if runfiles_prefix != None:
        if strip_prefix and not runfiles_prefix.startswith("../") and not executable_dsts[runfiles_prefix]:
            destination = _apply_strip_prefix(sp, strip_prefix, root)
            if destination != None:
                return destination
        runfiles_root = "/app" if executable_dsts[runfiles_prefix] else root
        return _apply_strip_prefix(sp, runfiles_prefix, runfiles_root)
    if sp.startswith("../"):
        if strip_prefix and (sp in executable_dsts or sp == strip_prefix):
            destination = _apply_strip_prefix(sp, strip_prefix, root)
            if destination != None:
                return destination
        if sp in executable_dsts:
            return _apply_strip_prefix(sp, sp, root)
        return "./app.runfiles/" + sp[3:]
    if strip_prefix and not any(executable_dsts.values()):
        destination = _apply_strip_prefix(sp, strip_prefix, root)
        if destination != None:
            return destination
    if sp in executable_dsts:
        return _apply_strip_prefix(sp, sp, root)
    return "./app.runfiles/_main/" + sp

# mtree escapes spaces as \040; must stay byte-identical between row emitters
# and the skip/chmod path sets or awk's set matching silently misses.
def _encode_mtree_path(path):
    return path.replace(" ", "\\040")

def _file_to_mtree_entry(
        f,
        mode = "0644",
        strip_prefix = "",
        root = "/",
        maybe_symlink = False,
        executable_dsts = {},
        owner = "0",
        group = "0"):
    dst = _source_destination(f.short_path, strip_prefix, root, executable_dsts)

    # `f.is_symlink` emits `type=link` (awk readlinks once); `maybe_symlink=True`
    # emits `type=file content=` (awk readlinks to detect repo-rule-staged
    # symlinks); default emits `type=file contents=` which skips awk entirely.
    if f.is_symlink:
        return "{} type=link mode={} uid={} gid={} time=1672560000 link={}".format(
            _encode_mtree_path(dst),
            mode,
            owner,
            group,
            _encode_mtree_path(f.path),
        )
    marker = "content" if maybe_symlink else "contents"
    return "{} type=file mode={} uid={} gid={} time=1672560000 {}={}".format(
        _encode_mtree_path(dst),
        mode,
        owner,
        group,
        marker,
        _encode_mtree_path(f.path),
    )

def _source_file_to_mtree(
        f,
        dir_expander,
        strip_prefix,
        root,
        maybe_symlink,
        executable_dsts,
        runfile_executable_paths,
        repo_mapping_path,
        owner = "0",
        group = "0"):
    if f.path == repo_mapping_path:
        return _file_to_mtree_entry(
            f,
            "0755",
            f.short_path,
            "/app.runfiles/_repo_mapping",
            owner = owner,
            group = group,
        )

    # 0755 throughout: keeps launcher/interpreter/venv shims executable; Bazel
    # doesn't expose per-input source mode for us to propagate.
    if f.is_directory:
        return [
            _file_to_mtree_entry(child, "0755", strip_prefix, root, maybe_symlink, executable_dsts, owner, group)
            for child in dir_expander.expand(f)
        ]
    entry = _file_to_mtree_entry(f, "0755", strip_prefix, root, maybe_symlink, executable_dsts, owner, group)
    if f.path not in runfile_executable_paths:
        return entry
    return [
        entry,
        _file_to_mtree_entry(
            f,
            "0755",
            maybe_symlink = maybe_symlink,
            owner = owner,
            group = group,
        ),
    ]

def _user_file_to_mtree(f, dir_expander, owner = "0", group = "0"):
    # Rule-level groups may contain declared symlinks that File.is_symlink
    # doesn't expose, so every grouped file needs the readlink fallback.
    # Source-closure files get 0755 via the tar action's chmod set.
    if f.is_directory:
        return [
            _file_to_mtree_entry(child, "0755", maybe_symlink = True, owner = owner, group = group)
            for child in dir_expander.expand(f)
        ]
    return _file_to_mtree_entry(f, "0644", maybe_symlink = True, owner = owner, group = group)

def _should_skip_pkg_path(p):
    return (
        "dist-info/RECORD" in p or "dist-info/INSTALLER" in p or
        "dist-info/WHEEL" in p or "dist-info/REQUESTED" in p or
        "/__pycache__/" in p or p.endswith(".whl")
    )

def _pkg_file_to_mtree(f, dir_expander, owner = "0", group = "0"):
    if f.is_directory:
        lines = []
        for child in dir_expander.expand(f):
            p = child.path
            if _should_skip_pkg_path(p):
                continue
            lines.append(_file_to_mtree_entry(child, "0755", owner = owner, group = group))
        return lines
    return [_file_to_mtree_entry(f, "0755", owner = owner, group = group)]

def _interpreter_file_to_mtree(f, dir_expander, owner = "0", group = "0"):
    # Interpreter repo stages `bin/python -> python3.11` symlinks `f.is_symlink`
    # doesn't catch, so opt into awk's readlink scan.
    if f.is_directory:
        lines = []
        for child in dir_expander.expand(f):
            p = child.path
            if _should_skip_pkg_path(p):
                continue
            lines.append(_file_to_mtree_entry(child, "0755", maybe_symlink = True, owner = owner, group = group))
        return lines
    return [_file_to_mtree_entry(f, "0755", maybe_symlink = True, owner = owner, group = group)]

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

def _make_glob_map_each(patterns, owner, group, invert = False):
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
                    lines.append(_file_to_mtree_entry(child, "0755", owner = owner, group = group))
            return lines
        if _matches(f.path):
            return [_file_to_mtree_entry(f, "0755", owner = owner, group = group)]
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

def _skip_path(f):
    # Trailing "/" marks a directory; consumers prefix-match its children.
    path = _encode_mtree_path(f.path)
    return path + "/" if f.is_directory else path

def _path_set_args(ctx, files_depsets):
    # One path per line, consumed by the awk path-set readers.
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("%s", use_always = True)
    for files in files_depsets:
        args.add_all(files, map_each = _skip_path, expand_directories = False)
    return args

def _declare_symlink_mapping(ctx, mappings):
    """Expand every mapping set's mtree rows into one shared file.

    Bazel writes `rows` to a param file, expanding tree artifacts as it does
    for any action argument; a gawk one-liner then copies that param file to
    the declared output. `ctx.actions.write` cannot be used instead: it has
    no inputs, and only tree artifacts that are action inputs can be
    expanded, which is also why the whole mapping closure is an input here.
    """
    mapping_out = ctx.actions.declare_file(ctx.attr.name + "_symlink_mappings.mtree")

    rows = ctx.actions.args()
    rows.set_param_file_format("multiline")
    rows.use_param_file("%s", use_always = True)
    rows.add("#mtree")
    for files, map_each in mappings:
        rows.add_all(files, map_each = map_each, expand_directories = False, allow_closure = True)

    copy_program = ctx.actions.args()
    copy_program.add("-v", mapping_out, format = "outfile=%s")
    copy_program.add("{ print > outfile }")

    ctx.actions.run(
        executable = ctx.executable._awk,
        inputs = depset(transitive = [files for files, _ in mappings]),
        outputs = [mapping_out],
        arguments = [copy_program, rows],
        env = {"LC_ALL": "C"},
        mnemonic = "PyImageLayerSymlinkMappings",
    )
    return mapping_out

def _run_tar_action(ctx, bsdtar, bsdtar_files, tar_out, files_depset, map_each, codec, reqs, mnemonic, progress_msg, symlink_mappings = None, skip_files = None, chmod_files = None):
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

    # Skip drops matching source rows; chmod forces them to 0755. Entries are
    # path strings only, so the referenced files are never action inputs.
    gawk_arguments = [gawk_args]
    gawk_inputs = [files_depset]
    next_argind = 1
    if skip_files != None:
        gawk_args.add("-v", str(next_argind), format = "skip_argind=%s")
        gawk_arguments.append(_path_set_args(ctx, [skip_files]))
        next_argind += 1
    if chmod_files != None:
        gawk_args.add("-v", str(next_argind), format = "chmod_argind=%s")
        gawk_arguments.append(_path_set_args(ctx, [chmod_files]))
        next_argind += 1
    gawk_args.add("-v", str(next_argind), format = "source_argind=%s")
    gawk_args.add("-f", awk_script)
    gawk_arguments.append(mtree_args)
    if symlink_mappings != None:
        # Own Args so the file lands in argv after the mtree param file: awk
        # treats files past source_argind as destination registrations only.
        mapping_file_arg = ctx.actions.args()
        mapping_file_arg.add(symlink_mappings)
        gawk_arguments.append(mapping_file_arg)
        gawk_inputs.append(depset(direct = [symlink_mappings]))
    ctx.actions.run(
        executable = awk,
        inputs = depset(direct = [awk_script], transitive = gawk_inputs),
        outputs = [sorted_mtree],
        arguments = gawk_arguments,
        # LC_ALL=C makes gawk's asort byte-stable.
        env = {"LC_ALL": "C"},
        mnemonic = mnemonic + "Mtree",
        progress_message = "Resolving symlinks for %{output}",
        execution_requirements = reqs,
    )

    tar_args = ctx.actions.args()
    tar_args.add("--create")
    codec_tar_args(codec, tar_args)
    tar_args.add("--file", tar_out)

    # `@<file>` tells bsdtar to read the named file as an mtree archive
    # (same as `@-` for stdin, just from disk).
    tar_args.add(sorted_mtree, format = "@%s")
    ctx.actions.run(
        executable = bsdtar.binary,
        inputs = depset(direct = [sorted_mtree], transitive = [files_depset, bsdtar_files.files]),
        outputs = [tar_out],
        arguments = [tar_args],
        # bsdtar spawns a custom compressor from the execroot.
        tools = codec_tools(codec),
        mnemonic = mnemonic,
        progress_message = progress_msg,
        execution_requirements = reqs,
        toolchain = _TAR_TOOLCHAIN,
        use_default_shell_env = False,
    )

def _rule_codecs(ctx):
    """Codecs the rule's own attrs pin, group name → codec."""
    codecs = {}
    for group_name, value in ctx.attr.group_compression.items():
        codec = parse_compression(value, "py_image_layer.group_compression[%r]" % group_name)
        check_oci_compatible(codec, group_name, "py_image_layer.group_compression", ctx.attr.allow_non_oci_layers)
        codecs[group_name] = codec
    seen = {}
    for dep, group_name in ctx.attr.group_compressors.items():
        # Duplicates first, for the same reason as py_layer_tier above.
        if group_name in seen:
            fail(("group %r is mapped to two py_layer_compressor targets (%s and %s) in " +
                  "py_image_layer.group_compressors. A group gets its bytes from exactly " +
                  "one compressor.") % (group_name, seen[group_name], dep.label))
        if group_name in codecs:
            fail(("group %r is configured in both py_image_layer.group_compression and " +
                  "py_image_layer.group_compressors. A group gets its bytes from exactly " +
                  "one compressor — drop one of the two entries.") % group_name)
        seen[group_name] = dep.label
        codec = codec_from_compressor(dep[PyLayerCompressorInfo])
        check_oci_compatible(codec, group_name, "py_image_layer.group_compressors", ctx.attr.allow_non_oci_layers)
        codecs[group_name] = codec
    return codecs

def _rule_codec_for(ctx, rule_codecs, plan, group_name):
    # Rule attrs win over the tier, so one image can deviate without forking a
    # shared tier; `group_compress_levels` is the gzip-only fallback.
    if group_name in rule_codecs:
        return rule_codecs[group_name]
    if group_name in plan.codecs:
        return plan.codecs[group_name]
    return make_codec(DEFAULT_ALGORITHM, ctx.attr.group_compress_levels.get(group_name, DEFAULT_LEVEL))

def _declare_group_tar(ctx, rule_codecs, plan, bsdtar, bsdtar_files, out_basename, group_name, files, map_each, progress, symlink_mappings = None, skip_files = None, chmod_files = None):
    codec = _rule_codec_for(ctx, rule_codecs, plan, group_name)
    tar_out = ctx.actions.declare_file(out_basename + codec.ext)
    reqs = _parse_exec_requirements(ctx.attr.group_execution_requirements.get(group_name, []))
    _run_tar_action(
        ctx,
        bsdtar,
        bsdtar_files,
        tar_out,
        files,
        map_each,
        codec,
        reqs,
        "PyImageLayer",
        progress,
        symlink_mappings,
        skip_files = skip_files,
        chmod_files = chmod_files,
    )
    return tar_out

def _py_image_layer_impl(ctx):
    binaries = ctx.attr.binaries
    if not binaries:
        fail("py_image_layer requires at least one binary")
    single_binary = len(binaries) == 1
    infos = [binary[_LayerInfo] for binary in binaries]
    bsdtar, bsdtar_files = _tar_toolchain(ctx)

    # Normalized labels can collide across lock universes, and one wheel target
    # can produce distinct artifacts under different Python configurations.
    pkg_by_key = {}
    for info in infos:
        for pkg in info.pip_packages.to_list():
            if pkg.artifact_key not in pkg_by_key:
                pkg_by_key[pkg.artifact_key] = pkg
    all_pkgs = pkg_by_key.values()
    pip_labels = {pkg.label: True for pkg in all_pkgs}

    # `_platform_cfg` rewrites the `//py:layer_tier` flag from `attr.layer_tier`,
    # so `_layer_tier` always resolves to the effective tier.
    plan = ctx.attr._layer_tier[PyLayerTierInfo]
    rule_codecs = _rule_codecs(ctx)
    root = plan.root
    strip_prefix = plan.strip_prefix
    owner = plan.owner
    group = plan.group
    launcher_dir = ctx.attr.launcher_dir
    if len(binaries) > 1 and not launcher_dir:
        launcher_dir = "/app/bin"
    if launcher_dir:
        launcher_dir = launcher_dir.rstrip("/") or "/"
    if launcher_dir and not launcher_dir.startswith("/"):
        fail("py_image_layer.launcher_dir must be an absolute image path")

    launcher_names = {}
    executable_dsts = {}
    executable_owner_by_path = {}
    repo_mappings_by_path = {}
    for index, binary in enumerate(binaries):
        files_to_run = binary[DefaultInfo].files_to_run
        executable = files_to_run.executable
        executable_owner_by_path[executable.path] = index
        repo_mapping = files_to_run.repo_mapping_manifest
        if repo_mapping != None:
            repo_mappings_by_path[repo_mapping.path] = repo_mapping
        launcher_name = executable.basename
        if launcher_dir:
            if launcher_name in launcher_names:
                fail("duplicate py_image_layer launcher basename: {}".format(launcher_name))
            launcher_names[launcher_name] = True
            executable_dsts[executable.short_path] = "." + launcher_dir.rstrip("/") + "/" + launcher_name
        else:
            executable_dsts[executable.short_path] = ""

    runfile_executable_paths = {}
    if launcher_dir and len(binaries) > 1:
        for index, binary in enumerate(binaries):
            for f in binary[DefaultInfo].default_runfiles.files.to_list():
                # Distinct from the tier's `owner` (the uid) — this is which
                # binary declares `f` as its executable.
                owning_binary = executable_owner_by_path.get(f.path, None)

                # A launcher consumed through another binary's runfiles needs
                # both its relocated entrypoint and the logical key resolved
                # by that consumer.
                if owning_binary != None and owning_binary != index:
                    runfile_executable_paths[f.path] = True

    # Each manifest describes one launcher's runfiles closure. The image shares
    # one runfiles root, so its manifest must resolve apparent names from all of
    # the explicitly listed launchers.
    repo_mappings = repo_mappings_by_path.values()
    repo_mapping = None
    if len(repo_mappings) == 1:
        repo_mapping = repo_mappings[0]
    elif len(repo_mappings) > 1:
        repo_mapping = ctx.actions.declare_file(ctx.attr.name + "/_repo_mapping")
        args = ctx.actions.args()
        args.add("-v")
        args.add("output=" + repo_mapping.path)
        args.add("-f")
        args.add(ctx.file._repo_mapping_merger)
        args.add_all(repo_mappings)
        ctx.actions.run(
            executable = ctx.executable._awk,
            inputs = depset(direct = [ctx.file._repo_mapping_merger] + repo_mappings),
            outputs = [repo_mapping],
            arguments = [args],
            env = {"LC_ALL": "C"},
            mnemonic = "PyImageRepoMapping",
            progress_message = "Merging repository mappings for %s" % ctx.label,
        )

    # 3p pip layers are action-shared across the graph and hard-code their
    # destination under `./app.runfiles/<repo>/...`, so the consumer's source
    # layer has to land under the same `/app.runfiles/` tree for each launcher
    # to find them. Map every launcher's `.runfiles/` tree into that shared root.
    all_tars = []
    source_maybe_symlink = any([info.interpreter_layer == None for info in infos])
    source_map = lambda f, d: _source_file_to_mtree(
        f,
        d,
        strip_prefix,
        root,
        source_maybe_symlink,
        executable_dsts,
        runfile_executable_paths,
        repo_mapping.path if repo_mapping != None else "",
        owner,
        group,
    )
    pkg_map = lambda f, d: _pkg_file_to_mtree(f, d, owner, group)
    interpreter_map = lambda f, d: _interpreter_file_to_mtree(f, d, owner, group)

    rule_group_names = {gname: True for gname in ctx.attr.groups.values()}
    rule_group_files = []
    rule_groups = []
    for dep, group_name in ctx.attr.groups.items():
        dep_label = normalize_label(str(dep.label))
        if dep_label in pip_labels:
            continue
        files = dep[DefaultInfo].files
        rule_group_files.append(files)
        rule_groups.append((group_name, files))

    source_files = depset(transitive = [info.source_files for info in infos])
    if repo_mapping != None:
        source_files = depset(direct = [repo_mapping], transitive = [source_files])
    rule_group_map = lambda f, d: (
        source_map(f, d) if f.short_path in executable_dsts else _user_file_to_mtree(f, d, owner, group)
    )

    first_party_reference_files = []
    fp_by_group = {}
    seen_fp_labels = {}
    for info in infos:
        for entry in info.first_party_layers.to_list():
            first_party_reference_files.append(entry.files)
            if single_binary:
                if entry.label in seen_fp_labels:
                    continue
                seen_fp_labels[entry.label] = True
            fp_by_group.setdefault(entry.group, []).append(entry.files)

    # Interpreter tars are declared at the configured toolchain, so identical
    # runtimes action-share while distinct interpreter artifacts are retained.
    interpreter_layers = {}
    for info in infos:
        if info.interpreter_layer != None:
            layer = info.interpreter_layer
            interpreter_layers[layer.tar.path] = layer

    # Non-default-layer file sets with their mtree mappers, lowest-priority
    # first (awk last-row-wins); the same sets feed the source tar's skip set.
    owned_sets = (
        [(files, source_map) for files in first_party_reference_files] +
        [(pkg.files, pkg_map) for pkg in all_pkgs] +
        [(layer.interpreter_files, interpreter_map) for layer in interpreter_layers.values()] +
        [(files, rule_group_map) for files in rule_group_files]
    )
    source_exclusion_files = [files for files, _ in owned_sets]

    # Each source-owned tier may contain a symlink whose target is emitted by
    # another tier. Share destination-only rows so every tar can rewrite those
    # links without copying the target bytes into that tar.
    symlink_mappings = None
    if rule_group_files or first_party_reference_files:
        symlink_mappings = _declare_symlink_mapping(ctx, [(source_files, source_map)] + owned_sets)

    for group_name, files in rule_groups:
        tar_out = _declare_group_tar(
            ctx,
            rule_codecs,
            plan,
            bsdtar,
            bsdtar_files,
            "{}_{}".format(ctx.attr.name, group_name),
            group_name,
            files,
            rule_group_map,
            "Creating image layer %s[%s]" % (ctx.label, group_name),
            symlink_mappings,
            chmod_files = source_files,
        )
        all_tars.append(tar_out)

    prebuilt_group_tars = {}
    if single_binary:
        for layer in interpreter_layers.values():
            prebuilt_group_tars[layer.group] = layer.tar
            fp_by_group.setdefault(layer.group, [])

    layer_group_names = {group_name: True for group_name in fp_by_group}
    layer_group_names.update({layer.group: True for layer in interpreter_layers.values()})
    for group_name in layer_group_names:
        if group_name in rule_group_names:
            fail(
                ("Group %r is declared in both py_image_layer.groups and the active " +
                 "py_layer_tier. Pick a unique name — the rule-level group tars ad-hoc " +
                 "deps with a different file layout than first-party sources, so they " +
                 "cannot share a tar.") % group_name,
            )
    for group_name in sorted(fp_by_group):
        if group_name in prebuilt_group_tars:
            tar_out = prebuilt_group_tars[group_name]
        else:
            tar_out = _declare_group_tar(
                ctx,
                rule_codecs,
                plan,
                bsdtar,
                bsdtar_files,
                "{}_{}".format(ctx.attr.name, group_name),
                group_name,
                depset(transitive = fp_by_group[group_name]),
                source_map,
                "Creating first-party layer %s[%s]" % (ctx.label, group_name),
                symlink_mappings,
            )
        all_tars.append(tar_out)

    if not single_binary:
        all_tars.extend([layer.tar for layer in interpreter_layers.values()])

    pip_tars = {}
    merged = {}
    for pkg in all_pkgs:
        for layer in pkg.layers:
            pip_tars[layer.tar.path] = layer.tar
        if not single_binary and pkg.merge_group != None:
            merged.setdefault(pkg.merge_group, []).append(pkg.files)

    all_tars.extend(pip_tars.values())

    if single_binary:
        all_tars.extend([tar for _group_name, tar in sorted(binaries[0][_MergedLayerInfo].merged_tars.items())])
    else:
        for group_name in sorted(merged):
            codec = _codec_for(plan, group_name)
            tar_out = ctx.actions.declare_file("{}/merged_pip_layers/{}{}".format(ctx.attr.name, group_name, codec.ext))
            _run_tar_action(
                ctx,
                bsdtar,
                bsdtar_files,
                tar_out,
                depset(transitive = merged[group_name]),
                pkg_map,
                codec,
                {},
                "PyImageMergedLayer",
                "Merging %d pip packages into %s[%s]" % (len(merged[group_name]), ctx.label, group_name),
            )
            all_tars.append(tar_out)

    ungrouped_pkgs = [p for p in all_pkgs if len(p.layers) == 0 and p.merge_group == None]
    if ungrouped_pkgs:
        squashed_tar = _declare_group_tar(
            ctx,
            rule_codecs,
            plan,
            bsdtar,
            bsdtar_files,
            "{}_squashed".format(ctx.attr.name),
            "packages",
            depset(transitive = [p.files for p in ungrouped_pkgs]),
            pkg_map,
            "Creating squashed pip layer (%d ungrouped packages) for %s" % (len(ungrouped_pkgs), ctx.label),
        )
        all_tars.append(squashed_tar)

    # dep_tars is identical to all_tars except for the source layer appended below;
    # snapshot here to avoid double-bookkeeping during construction.
    dep_tars = list(all_tars)

    source_tar = _declare_group_tar(
        ctx,
        rule_codecs,
        plan,
        bsdtar,
        bsdtar_files,
        "{}_default".format(ctx.attr.name),
        "default",
        source_files,
        source_map,
        "Creating source layer for %s" % ctx.label,
        symlink_mappings,
        skip_files = depset(transitive = source_exclusion_files) if source_exclusion_files else None,
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

    validation_inputs = [pkg.files for pkg in ungrouped_pkgs]
    validation_arguments = [validation_args]
    if len(binaries) > 1 or launcher_dir or strip_prefix or root != "/app":
        # Validate expanded rows whenever source destinations can be shared or remapped.
        # TreeArtifact roots can contain disjoint versioned children, so only
        # the production mappers' expanded destinations are authoritative.
        mtree_args = ctx.actions.args()
        mtree_args.set_param_file_format("multiline")
        mtree_args.use_param_file("%s", use_always = True)
        mtree_args.add("#mtree")
        mtree_args.add_all(source_files, map_each = source_map, expand_directories = False, allow_closure = True)

        # --skip applies only to the source rows above; owning-layer rows
        # below stay visible for collision checks.
        mtree_args.add("#end-source")
        for files, map_each in owned_sets:
            mtree_args.add_all(files, map_each = map_each, expand_directories = False, allow_closure = True)
        validation_args.add("--mtree")
        validation_arguments.append(mtree_args)

        validation_skip_args = _path_set_args(ctx, source_exclusion_files)
        validation_flag_args = ctx.actions.args()
        validation_flag_args.add("--skip")
        validation_arguments.extend([validation_flag_args, validation_skip_args])
        validation_inputs.extend([source_files] + source_exclusion_files)

    ctx.actions.run(
        executable = ctx.executable._validator,
        inputs = depset(transitive = validation_inputs),
        outputs = [validation],
        arguments = validation_arguments,
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
        "binaries": attr.label_list(
            allow_empty = False,
            aspects = [_layer_aspect, _merge_aspect],
            mandatory = True,
        ),
        "launcher_dir": attr.string(
            default = "",
            doc = "Absolute image directory for binary launchers. Defaults to /app/bin with multiple binaries.",
        ),
        "groups": attr.label_keyed_string_dict(default = {}),
        "group_execution_requirements": attr.string_list_dict(default = {}),
        "allow_non_oci_layers": attr.bool(default = False),
        "group_compress_levels": attr.string_dict(default = {}),
        "group_compression": attr.string_list_dict(default = {}),
        "group_compressors": attr.label_keyed_string_dict(
            default = {},
            cfg = "exec",
            providers = [PyLayerCompressorInfo],
        ),
        "warn_remote_cache_threshold_mb": attr.int(default = 200),
        "warn_layer_count": attr.int(default = 90),
        "platform": attr.label(default = None, providers = [platform_common.PlatformInfo]),
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
        "_repo_mapping_merger": attr.label(
            default = "//py/private:merge_repo_mappings.awk",
            allow_single_file = True,
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
        binary = None,
        groups = {},
        group_execution_requirements = {},
        group_compress_levels = {},
        group_compression = {},
        group_compressors = {},
        allow_non_oci_layers = False,
        warn_remote_cache_threshold_mb = 200,
        warn_layer_count = 90,
        platform = None,
        layer_tier = None,
        launcher_dir = "",
        binaries = None,
        **kwargs):
    """Create OCI-compatible tars from one or more py_binary targets.

    Pip-package grouping + compression is resolved from the `//py:layer_tier`
    label_flag. Override globally with `--//py:layer_tier=//path:custom_tier`,
    or pin a tier to a specific rule via the `py_layer_tier` attr below.

    ## Output layers

      1. Non-pip deps listed in `groups` → one rule-created tar per group.
      2. First-party py_library targets matched by `py_layer_tier.groups` → one
         rule-created tar per group (aggregated across all matched targets in the
         binary inputs' dep closures).
      3. Solo-group and subpath-split pip tars — built by `_layer_aspect` at each pip
         target's own namespace; globally shared across every rule using that package.
      4. Multi-member merged tars — action-shared for a single binary or one per
         group from the closure-filtered union across multiple binaries.
      5. Ungrouped pip packages → one squashed rule-created tar.
      6. Remaining first-party Python source files → the "default" layer.

    Args:
        name: Name of the generated target.
        binary: A py_binary target.
        groups: Maps a NON-PIP dep label to a group name. Each gets its own rule-created
            tar. All pip-package grouping (whole-package, subpath, multi-member) belongs
            in py_layer_tier — subpath glob keys passed here fail loudly.
        group_execution_requirements: Maps a group name to execution requirement strings.
            The group name "packages" applies to the squashed ungrouped-pip tar.
        group_compress_levels: gzip-only shorthand: maps a group name to a compression
            level (1-9) for rule-created tars. Default 6. Ignored for any group named by
            `group_compression`, `group_compressors`, or the tier's `compression`.
        group_compression: Maps a group name to `[algorithm]` or `[algorithm, level]` for
            rule-created tars (non-pip deps, first-party groups, the squashed ungrouped-pip
            tar under the name "packages", and the source layer under the name "default").
            `algorithm` is any bsdtar write filter — `none`, `gzip`, `bzip2`, `xz`, `lzma`,
            `lzop`, `lz4`, `lrzip`, `zstd`, `compress`. Takes precedence over the tier's
            `compression` for the same group. Does NOT apply to aspect-created pip tars;
            configure those on the py_layer_tier target.
        group_compressors: Maps a `py_layer_compressor` target to a group name, for rule-created
            tars that need a compressor libarchive has no filter for. Same precedence as
            `group_compression`; a group may appear in one or the other, not both.
        allow_non_oci_layers: Permit compression the OCI image spec has no layer format
            for. The spec defines only tar, gzip and zstd, and rules_oci labels anything
            else an uncompressed tar with the compressed digest as its diffid — the build
            succeeds and the image is invalid. Set this only when the tars are consumed by
            something other than an OCI image.
        warn_remote_cache_threshold_mb: Threshold for large package warnings.
        warn_layer_count: Warn when total layers exceed this. Default: 90.
        platform: Platform transition target.
        layer_tier: Optional py_layer_tier target pinned for this rule. Sets the
            `@aspect_rules_py//py:layer_tier` label_flag via the rule transition,
            overriding any command-line value for this rule's subgraph.
        launcher_dir: Absolute image directory for the binary launchers. Defaults
            to /app/bin with multiple binaries. Set RUNFILES_DIR=/app.runfiles in
            the image.
        binaries: Alternative to binary. A nonempty list of py_binary targets to
            include in the image.
        **kwargs: Forwarded to inner rule.
    """
    tags = kwargs.pop("tags", []) + ["manual"]

    if binaries != None:
        if binary != None:
            fail("py_image_layer accepts either binary or binaries, not both")
    else:
        if binary == None:
            fail("py_image_layer requires binary or binaries")
        binaries = [binary]

    for key in groups:
        if _split_glob_key(key)[1] != None:
            fail(
                "py_image_layer.groups no longer supports subpath (glob) keys like %r. " % key +
                "Move pip subpath grouping to py_layer_tier(groups = {...}) — the same dict accepts label:glob keys.",
            )

    _py_image_layer(
        name = name,
        binaries = binaries,
        launcher_dir = launcher_dir,
        groups = groups,
        group_execution_requirements = group_execution_requirements,
        group_compress_levels = group_compress_levels,
        group_compression = group_compression,
        group_compressors = group_compressors,
        allow_non_oci_layers = allow_non_oci_layers,
        warn_remote_cache_threshold_mb = warn_remote_cache_threshold_mb,
        warn_layer_count = warn_layer_count,
        platform = platform,
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
