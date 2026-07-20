"""Per-wheel repository rule: download a platform wheel and pin its layout.

Each locked bdist gets one `whl_dist` repo. It downloads the wheel and peeks at
its `*.dist-info/RECORD` / `entry_points.txt` to derive the site-packages
layout, then emits a `whl_dist` build rule carrying the `.whl` plus that layout
as `PyWheelMetadataInfo`.

Doing the peek here — rather than centrally in `whl_install` over every
selectable platform wheel — restores Bazel's lazy `select` fetching: only the
wheel a configuration actually resolves to is downloaded and inspected. A build
on a macOS host never fetches the Linux/Windows/musl wheels of a package.
"""

load("@bazel_tools//tools/build_defs/repo:cache.bzl", "DEFAULT_CANONICAL_ID_ENV", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private/pprint:defs.bzl", "indent", "pprint")
load(":metadata.bzl", "extract_install_metadata")

def _metadata_directory(basename):
    """The `<project>-<version>.dist-info` dir name, derived from the filename.

    Every wheel encodes its project and version in the filename with the same
    build-backend escaping the `.dist-info` dir uses, so no download is needed
    to know which member to strip. URL-encoded `+` is literal in the archive
    member; the build tag (absent from dist-info) is dropped by parse_whl_name.
    """
    whl_name = parse_whl_name(basename)
    return "{}-{}.dist-info".format(
        whl_name.project,
        whl_name.version.replace("%2B", "+").replace("%2b", "+"),
    )

def _attr(name, values):
    """Render one `whl_dist` string_list attr, or nothing when empty."""
    if not values:
        return ""
    return "\n    {} = {},".format(name, indent(pprint(list(values)), " " * 4).lstrip())

def _whl_dist_impl(rctx):
    basename = rctx.attr.downloaded_file_path

    # Mirror http_file's downloader contract: `auth` restores $NETRC / ~/.netrc
    # support for authenticated indexes, and the URL-derived `canonical_id`
    # stops a changed URL with a stale hash from reusing an old repo-cache entry.
    urls = [rctx.attr.url]
    download_info = rctx.download(
        url = urls,
        output = basename,
        sha256 = rctx.attr.sha256,
        canonical_id = get_default_canonical_id(rctx, urls),
        auth = get_auth(rctx, urls),
    )

    meta = extract_install_metadata(rctx, rctx.path(basename), _metadata_directory(basename))

    rctx.file("BUILD.bazel", content = """load("@aspect_rules_py//uv/private/whl_install:rule.bzl", "whl_dist")

whl_dist(
    name = "whl",
    src = {src},{top_levels}{top_level_dirs}{namespace_top_levels}{namespace_entries}{namespace_dirs}{regular_roots}{native_roots}{console_scripts}{record_paths}
    visibility = ["//visibility:public"],
)

exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""".format(
        src = repr(basename),
        top_levels = _attr("top_levels", meta.top_levels),
        top_level_dirs = _attr("top_level_dirs", meta.top_level_dirs),
        namespace_top_levels = _attr("namespace_top_levels", meta.namespace_top_levels),
        namespace_entries = _attr("namespace_entries", meta.namespace_entries),
        namespace_dirs = _attr("namespace_dirs", meta.namespace_dirs),
        regular_roots = _attr("regular_roots", meta.regular_roots),
        native_roots = _attr("native_roots", meta.native_roots),
        console_scripts = _attr("console_scripts", meta.console_scripts),
        # Only carried when a consuming package applies exclude_glob: whl_install
        # re-derives the layout from these after exclusion. Kept off every other
        # wheel so the common case doesn't pay for a full RECORD path list.
        record_paths = _attr("record_paths", meta.record_paths) if rctx.attr.carry_record_paths else "",
    ))

    # Hashless wheels record the discovered checksum so a re-fetch stays
    # pinned, matching http_file.
    if rctx.attr.sha256:
        return rctx.repo_metadata(reproducible = True)
    return rctx.repo_metadata(
        reproducible = False,
        attrs_for_reproducibility = {"sha256": download_info.sha256},
    )

whl_dist = repository_rule(
    implementation = _whl_dist_impl,
    doc = "Download one platform wheel and pin its RECORD-derived site-packages layout.",
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(),
        "downloaded_file_path": attr.string(
            mandatory = True,
            doc = "The wheel's file name; also the on-disk output name.",
        ),
        "carry_record_paths": attr.bool(
            doc = "Emit the retained RECORD paths so whl_install can re-derive " +
                  "the layout after exclude_glob. Set only for wheels of packages " +
                  "that declare exclude_glob.",
        ),
    },
    # Match http_file: the URL-derived canonical_id depends on this env var, so
    # flipping the policy must invalidate and refetch the wheel repo.
    environ = [DEFAULT_CANONICAL_ID_ENV],
)
