"""Wrapper extension that auto-resolves workspace-local UV binaries.

This extension wraps //uv:extension.bzl and automatically resolves the
custom UV binaries bundled in tools/uv/bin/ to absolute paths, making
the build portable across machines (dev laptops and CI).

Usage in MODULE.bazel:

    uv = use_extension("//tools/uv:extension.bzl", "uv")
    uv.toolchain(version = "0.11.6")
    uv.declare_hub(hub_name = "pypi")
    uv.project(...)
    use_repo(uv, "pypi", "uv", "uv_toolchains")
"""

load("//uv/private:gazelle.bzl", "gazelle_python_yaml_repository")
load("//uv/private/constraints/libc:repository.bzl", "libc_detector")
load("//uv/private/extension:defs.bzl", "uv_impl")
load("//uv/private/toolchain:repositories.bzl", "uv_host_repository", "uv_platform_repository", "uv_repository", "uv_toolchains_hub")

_SUPPORTED_PLATFORMS = [
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "aarch64-unknown-linux-gnu",
    "x86_64-unknown-linux-gnu",
    "x86_64-pc-windows-msvc",
    "aarch64-unknown-linux-musl",
    "x86_64-unknown-linux-musl",
]

# Workspace-relative paths to bundled UV binaries.
# These are resolved to absolute paths at extension evaluation time.
# Built from https://github.com/xangcastle/uv (xancastle/bazel-integration branch)
# with --mode=bazel-runfiles support.
_BUNDLED_BINARIES = {
    "aarch64-apple-darwin": Label("//tools/uv/bin/aarch64-apple-darwin:uv"),
    "x86_64-apple-darwin": Label("//tools/uv/bin/x86_64-apple-darwin:uv"),
    "aarch64-unknown-linux-gnu": Label("//tools/uv/bin/aarch64-unknown-linux-gnu:uv"),
    "x86_64-unknown-linux-gnu": Label("//tools/uv/bin/x86_64-unknown-linux-gnu:uv"),
    "aarch64-unknown-linux-musl": Label("//tools/uv/bin/aarch64-unknown-linux-musl:uv"),
    "x86_64-unknown-linux-musl": Label("//tools/uv/bin/x86_64-unknown-linux-musl:uv"),
    # NOTE: x86_64-pc-windows-msvc cannot be cross-compiled from macOS.
    # Build natively on Windows if needed.
}

def _uv_with_local_binaries_impl(mctx):
    """UV extension that auto-resolves bundled binaries for CI portability."""

    version = "0.5.27"
    local_path = None
    local_paths = {}
    for mod in mctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.version:
                version = toolchain.version
            if toolchain.local_path:
                local_path = toolchain.local_path
            if toolchain.local_paths:
                local_paths.update(toolchain.local_paths)

    # Auto-resolve bundled binaries: if no explicit local_paths were provided
    # for a platform, check if we have a bundled binary for it.
    for platform, label in _BUNDLED_BINARIES.items():
        if platform not in local_paths:
            resolved = mctx.path(label)
            if resolved:
                local_paths[platform] = str(resolved)

    # If no explicit local_path was set, use the host-matching bundled binary
    if not local_path:
        for platform, label in _BUNDLED_BINARIES.items():
            # Try to detect if this is the host platform
            resolved = mctx.path(label)
            if resolved:
                local_path = str(resolved)
                break

    for platform in _SUPPORTED_PLATFORMS:
        repo_name = "uv_{}_{}".format(
            version.replace(".", "_"),
            platform.replace("-", "_"),
        )
        platform_local_path = local_paths.get(platform, None)
        uv_repository(
            name = repo_name,
            version = version,
            platform = platform,
            local_path = platform_local_path,
        )

    uv_platform_repository(
        name = "uv",
        version = version,
        local_path = local_path,
    )

    uv_host_repository(
        name = "aspect_rules_py_uv_toolchain",
        version = version,
        local_path = local_path,
    )

    libc_detector(name = "uv_libc_detection")

    result = uv_impl(mctx)

    for mod in mctx.modules:
        for manifest in mod.tags.gazelle_manifest:
            gazelle_python_yaml_repository(
                name = manifest.name,
                uv_lock = manifest.lock,
                hub_name = manifest.hub,
                modules_mapping = manifest.modules_mapping,
            )

    uv_toolchains_hub(
        name = "uv_toolchains",
        version = version,
        platforms = _SUPPORTED_PLATFORMS,
    )

    return result

_toolchain_tag = tag_class(
    attrs = {
        "version": attr.string(
            doc = "The UV version to use",
            default = "0.5.27",
        ),
        "local_path": attr.string(
            doc = "Absolute path to a local UV binary. Overrides bundled binaries for host platform.",
        ),
        "local_paths": attr.string_dict(
            doc = "Map of platform -> absolute path to local UV binary. Overrides bundled binaries.",
        ),
    },
    doc = "Configures the UV toolchain version",
)

_hub_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "target_platforms": attr.string_list(
            mandatory = False,
            default = [],
        ),
    },
)

_project_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "name": attr.string(mandatory = False),
        "version": attr.string(mandatory = False),
        "python_version": attr.string(
            mandatory = True,
            doc = "Python version to use for uv lock resolution (e.g. '3.11').",
        ),
        "pyproject": attr.label(mandatory = True),
        "lock": attr.label(mandatory = True),
        "elide_sbuilds_with_anyarch": attr.bool(mandatory = False, default = True),
        "default_build_dependencies": attr.string_list(
            mandatory = False,
            default = ["build"],
        ),
        "unstable_configure_command": attr.string_list(mandatory = False),
    },
)

_annotations_tag = tag_class(
    attrs = {
        "lock": attr.label(mandatory = True),
        "src": attr.label(mandatory = True),
    },
)

_override_package_tag = tag_class(
    attrs = {
        "lock": attr.label(mandatory = True),
        "name": attr.string(mandatory = True),
        "version": attr.string(mandatory = False),
        "target": attr.label(mandatory = False),
        "pre_build_patches": attr.label_list(default = [], allow_files = [".patch", ".diff"]),
        "pre_build_patch_strip": attr.int(default = 0),
        "post_install_patches": attr.label_list(default = [], allow_files = [".patch", ".diff"]),
        "post_install_patch_strip": attr.int(default = 0),
        "extra_deps": attr.label_list(default = []),
        "extra_data": attr.label_list(default = []),
    },
)

_gazelle_manifest_tag = tag_class(
    attrs = {
        "name": attr.string(mandatory = True),
        "lock": attr.label(mandatory = True, allow_single_file = [".lock"]),
        "hub": attr.string(mandatory = True),
        "modules_mapping": attr.string_dict(default = {}),
    },
)

uv = module_extension(
    implementation = _uv_with_local_binaries_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
        "declare_hub": _hub_tag,
        "project": _project_tag,
        "unstable_annotate_packages": _annotations_tag,
        "override_package": _override_package_tag,
        "gazelle_manifest": _gazelle_manifest_tag,
    },
    doc = """UV extension with auto-resolved local binaries for CI portability.
    
    Wraps //uv:extension.bzl but automatically resolves bundled UV binaries
    from tools/uv/bin/ so builds work without absolute paths to external
    directories.
    """,
)
