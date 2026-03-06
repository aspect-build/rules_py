"""Module extension for provisioning Python interpreters from python-build-standalone."""

load(":repository.bzl", "python_interpreter", "python_toolchains")
load(":versions.bzl", "DEFAULT_RELEASE_BASE_URL", "MINOR_MAPPING", "PLATFORMS", "TOOL_VERSIONS")

def _sanitize(s):
    """Replace characters that are invalid in Bazel repo names."""
    return s.replace(".", "_").replace("-", "_")

def _resolve_version(version):
    """Resolve a version like '3.12' to a full patch version like '3.12.12'."""
    if version in MINOR_MAPPING:
        return MINOR_MAPPING[version]
    if version in TOOL_VERSIONS:
        return version
    fail("Unknown Python version '{}'. Available: {}".format(
        version,
        ", ".join(sorted(TOOL_VERSIONS.keys())),
    ))

def _python_interpreters_impl(module_ctx):
    # Collect all requested versions, respecting is_default ordering.
    default_version = None
    versions = {}

    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            full_version = _resolve_version(tag.python_version)
            if tag.is_default:
                if default_version and default_version != full_version:
                    fail("Multiple default Python versions specified: {} and {}".format(
                        default_version,
                        full_version,
                    ))
                default_version = full_version
            versions[full_version] = True

    if not versions:
        return

    # If no default, pick the first one
    if not default_version:
        default_version = sorted(versions.keys())[0]

    # Order versions: default first, then the rest sorted
    ordered = [default_version] + sorted([v for v in versions if v != default_version])

    # Create per-platform interpreter repos and collect toolchain entries
    toolchain_entries = []
    repos = []

    for version in ordered:
        version_info = TOOL_VERSIONS[version]
        url_template = version_info["url"]
        strip_prefix = version_info["strip_prefix"]
        sha256s = version_info["sha256"]

        for platform_triple, sha256 in sha256s.items():
            if platform_triple not in PLATFORMS:
                continue

            platform_info = PLATFORMS[platform_triple]
            repo_name = "python_{}_{}".format(
                _sanitize(version),
                _sanitize(platform_triple),
            )

            url = "{}/{}".format(
                DEFAULT_RELEASE_BASE_URL,
                url_template.format(
                    python_version = version,
                    platform = platform_triple,
                ),
            )

            python_interpreter(
                name = repo_name,
                python_version = version,
                platform = platform_triple,
                url = url,
                sha256 = sha256,
                strip_prefix = strip_prefix,
            )
            repos.append(repo_name)

            toolchain_name = "python_{}_{}".format(
                _sanitize(version),
                _sanitize(platform_triple),
            )
            toolchain_entries.append(json.encode({
                "name": toolchain_name,
                "repo": repo_name,
                "compatible_with": platform_info["compatible_with"],
                "python_version": version,
            }))

    # Create the toolchains hub repo
    python_toolchains(
        name = "python_interpreters",
        toolchains = toolchain_entries,
    )
    repos.append("python_interpreters")

_toolchain_tag = tag_class(
    attrs = {
        "is_default": attr.bool(default = False),
        "python_version": attr.string(mandatory = True),
    },
)

python_interpreters = module_extension(
    implementation = _python_interpreters_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
    },
)
