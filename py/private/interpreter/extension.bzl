"""Module extension for provisioning Python interpreters from python-build-standalone."""

load(":repository.bzl", "python_interpreter", "python_toolchains")
load(":versions.bzl", "DEFAULT_RELEASE_DATES", "PLATFORMS", "RELEASES")

def _sanitize(s):
    """Replace characters that are invalid in Bazel repo names."""
    return s.replace(".", "_").replace("-", "_")

def _find_release_for_version(major_minor, release_dates, releases):
    """Find the newest release date that contains the given Python minor version.

    Args:
        major_minor: Python version like "3.11"
        release_dates: List of release dates, newest-first
        releases: Dict mapping release date -> list of available minor versions

    Returns:
        The newest release date containing this version, or None.
    """
    for date in release_dates:
        if date in releases and major_minor in releases[date]:
            return date
    return None

def _python_interpreters_impl(module_ctx):
    # Collect release dates from tags, falling back to defaults
    release_dates = []
    custom_releases = {}
    has_release_tags = False

    for mod in module_ctx.modules:
        for tag in mod.tags.release:
            has_release_tags = True
            date = tag.date
            if date not in release_dates:
                release_dates.append(date)
                # For custom releases, we don't know the available versions
                # upfront. The repo rule will discover them from SHA256SUMS.
                # We mark them with an empty list; _find_release_for_version
                # will skip them, and they'll be used as explicit overrides.
                if date not in RELEASES:
                    custom_releases[date] = True

    # Merge in default releases for version routing (but only if they weren't
    # explicitly listed, to preserve user ordering)
    all_releases = dict(RELEASES)
    for date in custom_releases:
        all_releases[date] = []

    if not has_release_tags:
        release_dates = list(DEFAULT_RELEASE_DATES)

    # Sort newest-first for "prefer newest" semantics
    release_dates = sorted(release_dates, reverse = True)

    # Collect all requested toolchains
    default_version = None
    toolchain_requests = {}

    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            version = tag.python_version
            build_config = tag.build_config

            # Normalize: "3.11.14" -> major_minor "3.11"
            parts = version.split(".")
            if len(parts) < 2:
                fail("python_version must be at least major.minor, got '{}'".format(version))
            major_minor = "{}.{}".format(parts[0], parts[1])

            if tag.is_default:
                if default_version and default_version != major_minor:
                    fail("Multiple default Python versions specified: {} and {}".format(
                        default_version,
                        major_minor,
                    ))
                default_version = major_minor

            key = (major_minor, build_config)
            if key not in toolchain_requests:
                # Find which release to use for this version
                release_date = _find_release_for_version(major_minor, release_dates, all_releases)

                if release_date == None:
                    # If user provided custom releases, try them (repo rule will validate)
                    if custom_releases:
                        release_date = release_dates[0]
                    else:
                        fail(("Python {} not found in any configured release. " +
                              "Available releases: {}. " +
                              "Add an older release with interpreters.release(date = \"...\") " +
                              "to include this version.").format(
                            major_minor,
                            ", ".join(release_dates),
                        ))

                toolchain_requests[key] = struct(
                    major_minor = major_minor,
                    release_date = release_date,
                    build_config = build_config,
                )

    if not toolchain_requests:
        return

    # If no default, pick the first one
    if not default_version:
        default_version = sorted(toolchain_requests.keys())[0][0]

    # Order: default version first, then sorted. This affects toolchain
    # resolution priority when no version flag is set.
    ordered_keys = []
    for key in sorted(toolchain_requests.keys()):
        if key[0] == default_version:
            ordered_keys.insert(0, key)
        else:
            ordered_keys.append(key)

    # Create per-platform interpreter repos and collect toolchain entries
    toolchain_entries = []

    for key in ordered_keys:
        req = toolchain_requests[key]

        for platform_triple, platform_info in PLATFORMS.items():
            repo_name = "python_{}_{}".format(
                _sanitize(req.major_minor),
                _sanitize(platform_triple),
            )
            if req.build_config != "install_only":
                repo_name += "_" + _sanitize(req.build_config)

            python_interpreter(
                name = repo_name,
                release_date = req.release_date,
                major_minor = req.major_minor,
                platform = platform_triple,
                build_config = req.build_config,
            )

            toolchain_entries.append(json.encode({
                "name": repo_name,
                "repo": repo_name,
                "compatible_with": platform_info["compatible_with"],
            }))

    # Create the toolchains hub repo
    python_toolchains(
        name = "python_interpreters",
        toolchains = toolchain_entries,
    )

_release_tag = tag_class(
    attrs = {
        "date": attr.string(mandatory = True, doc = """\
A python-build-standalone release date (e.g. "20251209").
See https://github.com/astral-sh/python-build-standalone/releases for available releases.
"""),
    },
    doc = "Specify a python-build-standalone release to use for interpreter provisioning.",
)

_toolchain_tag = tag_class(
    attrs = {
        "build_config": attr.string(
            default = "install_only",
            doc = "The PBS build configuration to use. One of: install_only, install_only_stripped, freethreaded+pgo+lto, freethreaded+debug.",
        ),
        "is_default": attr.bool(default = False),
        "python_version": attr.string(
            mandatory = True,
            doc = "Python version to provision, e.g. '3.11' or '3.11.14'. The newest available patch version is used.",
        ),
    },
)

python_interpreters = module_extension(
    implementation = _python_interpreters_impl,
    tag_classes = {
        "release": _release_tag,
        "toolchain": _toolchain_tag,
    },
)
