"""Public module extension for UV-based Python dependency management (Graph-based).

This module provides a Bazel module extension for resolving Python dependencies
using a granular graph-based architecture (uv_hub + uv_project) with full
hermeticity, RBE support, and cross-platform wheel selection.

Example usage in MODULE.bazel:
    uv = use_extension("@aspect_rules_py//uv:extension.bzl", "uv")
    uv.toolchain(version = "0.5.27")
    uv.declare_hub(
        hub_name = "pypi",
    )
    uv.project(
        hub_name = "pypi",
        name = "my_project",
        pyproject = "//:pyproject.toml",
        lock = "//:uv.lock",
    )
    uv.gazelle_manifest(
        name = "pypi_gazelle",
        hub = "pypi",
        lock = "//:uv.lock",
    )
    use_repo(uv, "pypi", "pypi_gazelle", "uv")
"""

load("//uv/unstable:gazelle.bzl", "gazelle_python_yaml_repository")
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

def _uv_unstable_impl(mctx):
    """Implementation of the UV module extension (graph-based + toolchain + gazelle)."""

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
            doc = "Absolute path to a local UV binary with bazel-runfiles support. Skips download for host platform.",
        ),
        "local_paths": attr.string_dict(
            doc = "Map of platform -> absolute path to local UV binary with bazel-runfiles support. Overrides download for specific platforms.",
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
            doc = """\
List of target platforms to download wheels for. When empty, wheels for all
platforms found in uv.lock are downloaded. Supported values: linux_aarch64,
linux_x86_64, macos_aarch64, macos_x86_64, windows_x86_64, windows_arm64.
""",
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
        "unstable_configure_command": attr.string_list(
            mandatory = False,
            doc = "Command to run as the sdist configure tool. Each element is either " +
                  "a literal string argument or a $(location <label>) expansion. " +
                  "The archive path and context file are appended as the final two " +
                  "arguments. When set, replaces the default native-detection tool. " +
                  "See //uv/private/sdist_configure:defs.bzl for the contract.",
        ),
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
        "pre_build_patches": attr.label_list(
            default = [],
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply to the sdist source tree before building a wheel.",
        ),
        "pre_build_patch_strip": attr.int(
            default = 0,
            doc = "Strip count for pre-build patches (-p flag to the patch tool).",
        ),
        "post_install_patches": attr.label_list(
            default = [],
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply to the installed package after wheel unpacking.",
        ),
        "post_install_patch_strip": attr.int(
            default = 0,
            doc = "Strip count for post-install patches (-p flag to the patch tool).",
        ),
        "extra_deps": attr.label_list(
            default = [],
            doc = "Additional deps to add to the package's py_library target.",
        ),
        "extra_data": attr.label_list(
            default = [],
            doc = "Additional data files to add to the package's py_library target.",
        ),
    },
    doc = """Override or modify a Python package resolved from a lockfile.

Use `target` for full replacement, or use the patch/exclude attributes
for surgical modifications. Specifying `target` is mutually exclusive with
all other modification attributes.""",
)

_gazelle_manifest_tag = tag_class(
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the gazelle manifest repository to create",
        ),
        "lock": attr.label(
            mandatory = True,
            allow_single_file = [".lock"],
            doc = "The uv.lock file",
        ),
        "hub": attr.string(
            mandatory = True,
            doc = "Name of the hub repository (for reference)",
        ),
        "modules_mapping": attr.string_dict(
            default = {},
            doc = """Import name to package name mappings.

            For packages where the import name differs from the package name.
            Example: {"PIL": "pillow", "bs4": "beautifulsoup4"}
            """,
        ),
    },
    doc = "Creates a gazelle_python.yaml from uv.lock for Gazelle Python integration",
)

uv = module_extension(
    implementation = _uv_unstable_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
        "declare_hub": _hub_tag,
        "project": _project_tag,
        "unstable_annotate_packages": _annotations_tag,
        "override_package": _override_package_tag,
        "gazelle_manifest": _gazelle_manifest_tag,
    },
    doc = """UV module extension for hermetic Python dependency management.

    This extension uses a graph-based architecture (uv_hub + uv_project) where
    Bazel orchestrates each dependency in isolation. No uv invocation occurs
    at build time; all resolution happens during repository phase.
    """,
)
