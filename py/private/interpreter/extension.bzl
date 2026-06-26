"""Module extension for provisioning Python interpreters from python-build-standalone."""

load(":repository.bzl", "python_interpreter", "python_toolchains")
load(":version_util.bzl", "is_decimal", "is_pre_release", "version_gt")
load(":versions.bzl", "DEFAULT_RELEASE_BASE_URL", "DEFAULT_RELEASE_DATES", "PLATFORMS", "RUNTIME_MODES")

# The GitHub API endpoint for resolving "latest" releases.
_GITHUB_API_LATEST = "https://api.github.com/repos/{owner}/{repo}/releases/latest"

# Facts can outlive an extension implementation change, so index shape changes
# must use a new key rather than accepting cached data from the old schema.
_RELEASE_INDEX_SCHEMA = 1

def _sanitize(s):
    """Replace characters that are invalid in Bazel repo names."""
    return s.replace(".", "_").replace("-", "_").replace("+", "_")

def _parse_sha256sums(content, release_date):
    """Parse a SHA256SUMS file into a structured index.

    Returns a dict mapping (major_minor, platform, runtime_mode) -> {
        "sha256": str,
        "filename": str,
        "full_version": str,
    }

    When multiple patch versions exist for the same major.minor, only the
    newest is kept.
    """
    index = {}
    configured_assets = {}

    for platform, platform_info in PLATFORMS.items():
        for mode_name, mode_info in RUNTIME_MODES.items():
            asset = "{}-{}.{}".format(
                platform,
                platform_info["asset_suffixes"][mode_name],
                mode_info["extension"],
            )
            configured_assets[asset] = (platform, mode_name)

    for line in content.split("\n"):
        line = line.strip()
        if not line or not line[0].isalnum():
            continue

        parts = line.split("  ", 1)
        if len(parts) != 2:
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue

        sha256 = parts[0].strip()
        filename = parts[1].strip()

        if not filename.startswith("cpython-"):
            continue

        # Parse: cpython-{version}+{date}-{platform}-{suffix}.{ext}
        plus_idx = filename.find("+")
        if plus_idx < 0:
            continue
        version = filename[len("cpython-"):plus_idx]

        version_parts = version.split(".")
        if len(version_parts) < 2:
            continue
        major_minor = "{}.{}".format(version_parts[0], version_parts[1])

        # Match the complete platform, suffix, and extension.
        remainder = filename[plus_idx + 1 + len(release_date) + 1:]  # skip "{date}-"
        matched_asset = configured_assets.get(remainder)
        if not matched_asset:
            continue
        matched_platform, matched_mode = matched_asset

        key = "{}/{}/{}".format(major_minor, matched_platform, matched_mode)

        # Keep the newest patch version
        existing = index.get(key)
        if existing and not version_gt(version, existing["full_version"]):
            continue

        index[key] = {
            "sha256": sha256,
            "filename": filename,
            "full_version": version,
        }

    return index

def _release_index_facts_key(release_date, base_url):
    return "release_index_v{}_{}_{}".format(_RELEASE_INDEX_SCHEMA, release_date, base_url)

def _owner_repo_from_base_url(base_url):
    """Extract GitHub owner/repo from a base URL like https://github.com/{owner}/{repo}/releases/download."""
    parts = base_url.split("/")

    # Expected: ["https:", "", "github.com", "{owner}", "{repo}", "releases", "download"]
    if len(parts) >= 5 and "github.com" in parts[2]:
        return parts[3], parts[4]
    return None, None

def _resolve_latest(module_ctx, base_url):
    """Resolve "latest" to an actual release date tag via the GitHub releases API.

    Returns the tag_name string (e.g. "20260303").
    """
    owner, repo = _owner_repo_from_base_url(base_url)
    if not owner:
        fail(
            'Cannot resolve "latest" for base_url "{}": '.format(base_url) +
            "only GitHub-hosted repositories support automatic latest resolution. " +
            "Use an explicit release date instead.",
        )

    api_url = _GITHUB_API_LATEST.format(owner = owner, repo = repo)
    module_ctx.report_progress('Resolving "latest" PBS release via GitHub API')
    result_path = module_ctx.path("latest_release.json")
    module_ctx.download(
        url = [api_url],
        output = result_path,
    )
    content = module_ctx.read(result_path)
    release_info = json.decode(content)
    tag = release_info.get("tag_name")
    if not tag:
        fail('Could not resolve "latest" release from {}'.format(api_url))
    return tag

def _fetch_release_index(module_ctx, release_date, base_url, facts):
    """Fetch and parse SHA256SUMS for a release, using facts as cache.

    Returns the parsed index dict for this release date.
    """
    facts_key = _release_index_facts_key(release_date, base_url)
    cached = facts.get(facts_key)
    if cached:
        return cached

    # Download SHA256SUMS
    sha256sums_url = "{}/{}/SHA256SUMS".format(base_url, release_date)
    module_ctx.report_progress("Fetching SHA256SUMS for PBS release {}".format(release_date))
    sha256sums_path = module_ctx.path("sha256sums_{}".format(release_date))
    module_ctx.download(
        url = [sha256sums_url],
        output = sha256sums_path,
    )
    content = module_ctx.read(sha256sums_path)

    index = _parse_sha256sums(content, release_date)
    if not index:
        fail(
            "No CPython assets found in SHA256SUMS for release date \"{}\". ".format(release_date) +
            "Check that this is a valid python-build-standalone release date. " +
            "Available releases: https://github.com/astral-sh/python-build-standalone/releases",
        )
    return index

def _python_interpreters_impl(module_ctx):
    has_facts = hasattr(module_ctx, "facts")

    # Facts is a special Bazel type that supports .get() but is not iterable.
    # We read from it with .get(key) and build a new dict for output.
    facts = module_ctx.facts if has_facts else {}

    # Track whether the extension is reproducible. Using "latest" as a release
    # date makes it non-reproducible since the resolution depends on when it runs.
    is_reproducible = True
    resolved_latest = None

    # Collect release configuration from the root module only.
    # Non-root configure() tags are silently ignored — this allows rules_py
    # to carry a configure() for development without breaking downstream users.
    release_dates = []
    release_base_urls = {}  # date -> base_url
    has_configure = False

    for mod in module_ctx.modules:
        for tag in mod.tags.configure:
            if not mod.is_root:
                continue
            if has_configure:
                fail(
                    "Only one interpreters.configure() tag is allowed. " +
                    "Pass all release dates as a single list.",
                )
            has_configure = True
            base_url = tag.base_url if tag.base_url else DEFAULT_RELEASE_BASE_URL
            for date in tag.releases:
                if date == "latest":
                    is_reproducible = False
                    date = _resolve_latest(module_ctx, base_url)
                    resolved_latest = date
                if len(date) != 8 or not is_decimal(date):
                    fail(
                        "PBS release identifiers must be eight decimal digits, got '{}'".format(date),
                    )
                if date not in release_dates:
                    release_dates.append(date)
                    release_base_urls[date] = base_url

    if not has_configure:
        release_dates = list(DEFAULT_RELEASE_DATES)
        for date in release_dates:
            release_base_urls[date] = DEFAULT_RELEASE_BASE_URL

    # Sort newest-first for "prefer newest release" semantics
    release_dates = sorted(release_dates, reverse = True)

    # Collect all requested Python versions. Any module can request a version,
    # but only the root module's pre_release flag and toolchain settings are
    # honored.
    requested_versions = []
    version_sources = {}  # major_minor -> list of module names (for error messages)
    allow_pre_release = {}  # major_minor -> bool
    root_settings = {}  # major_minor -> root-owned toolchain settings

    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            version = tag.python_version

            parts = version.split(".")
            if len(parts) != 2 or not is_decimal(parts[0]) or not is_decimal(parts[1]):
                fail(
                    (
                        "module '{}' requested invalid python_version '{}'; expected " +
                        "major.minor"
                    ).format(
                        mod.name,
                        version,
                    ),
                )
            major_minor = version

            if mod.is_root:
                settings = {
                    "config_settings": sorted([str(label) for label in tag.config_settings]),
                    "exec_compatible_with": sorted([str(label) for label in tag.exec_compatible_with]),
                    "target_compatible_with": sorted([str(label) for label in tag.target_compatible_with]),
                }
                if major_minor in root_settings and root_settings[major_minor] != settings:
                    fail(
                        "Conflicting root toolchain settings for Python {}: {} and {}. ".format(
                            major_minor,
                            root_settings[major_minor],
                            settings,
                        ) +
                        "Tags requesting the same Python version " +
                        "must use identical config_settings, target_compatible_with, and " +
                        "exec_compatible_with.",
                    )
                root_settings[major_minor] = settings

            if major_minor not in requested_versions:
                requested_versions.append(major_minor)
                version_sources[major_minor] = []
            version_sources[major_minor].append(mod.name)

            # Pre-release policy is root-module-only. A non-root module
            # requesting 3.15 needs the root to allow pre-releases for that
            # version.
            if mod.is_root and tag.pre_release:
                allow_pre_release[major_minor] = True
            elif major_minor not in allow_pre_release:
                allow_pre_release[major_minor] = False

    if not requested_versions:
        return _return_metadata(module_ctx, has_facts, facts, is_reproducible, resolved_latest)

    new_facts = {}
    release_indices = {}

    for date in release_dates:
        base_url = release_base_urls.get(date, DEFAULT_RELEASE_BASE_URL)
        index = _fetch_release_index(module_ctx, date, base_url, facts)
        release_indices[date] = index

        # Cache in facts for next run — but never cache under "latest"
        facts_key = _release_index_facts_key(date, base_url)
        new_facts[facts_key] = index

    # Create per-platform, per-runtime-mode interpreter repos and collect
    # toolchain entries. Version and freethreaded target settings determine
    # which entries are eligible.
    toolchain_entries = []

    # Keep generated output stable: regular modes, then freethreaded modes.
    ordered_modes = (
        [(name, mode) for name, mode in RUNTIME_MODES.items() if not mode["freethreaded"]] +
        [(name, mode) for name, mode in RUNTIME_MODES.items() if mode["freethreaded"]]
    )

    # Target-pattern registration orders toolchains lexicographically by name,
    # so BUILD declaration order cannot select a default toolchain:
    # https://bazel.build/extending/toolchains#registering-building-toolchains
    for major_minor in sorted(requested_versions):
        version_found = False
        settings = root_settings.get(major_minor, {
            "config_settings": [],
            "exec_compatible_with": [],
            "target_compatible_with": [],
        })
        for mode_name, mode_info in ordered_modes:
            for platform_triple, platform_info in PLATFORMS.items():
                repo_name = "python_{}_{}".format(
                    _sanitize(major_minor),
                    _sanitize(platform_triple),
                )
                if mode_name != "install_only":
                    repo_name += "_" + _sanitize(mode_name)

                # Find the best release for this version/platform/mode
                asset_info = _find_asset(
                    major_minor,
                    platform_triple,
                    mode_name,
                    release_dates,
                    release_indices,
                )

                if not asset_info:
                    # Version/platform/mode combo doesn't exist — skip it
                    # rather than registering a stub toolchain.
                    continue

                # Skip pre-release versions unless explicitly allowed
                if is_pre_release(asset_info["full_version"]) and not allow_pre_release.get(major_minor, False):
                    continue

                version_found = True

                base_url = release_base_urls.get(asset_info["release_date"], DEFAULT_RELEASE_BASE_URL)
                url = "{}/{}/{}".format(
                    base_url,
                    asset_info["release_date"],
                    asset_info["filename"],
                )
                python_interpreter(
                    name = repo_name,
                    abi_flags = mode_info["abi_flags"],
                    python_version = asset_info["full_version"],
                    platform = platform_triple,
                    url = url,
                    sha256 = asset_info["sha256"],
                    strip_prefix = mode_info["strip_prefix"],
                )

                toolchain_entries.append(json.encode({
                    "name": repo_name,
                    "repo": repo_name,
                    "python_version": major_minor,
                    "freethreaded": mode_info["freethreaded"],
                    "compatible_with": platform_info["compatible_with"],
                    "platform_target_settings": platform_info.get("target_settings", {}),
                    "config_settings": settings["config_settings"],
                    "target_compatible_with": settings["target_compatible_with"],
                    "exec_compatible_with": settings["exec_compatible_with"],
                    "register_exec_tools": platform_info["register_exec_tools"],
                }))

        if not version_found:
            sources = version_sources.get(major_minor, ["unknown"])
            fail(
                "No CPython {} builds found in any configured PBS release. ".format(major_minor) +
                "Requested by module(s): {}. ".format(", ".join(sources)) +
                "The root module's interpreters.configure(releases = [...]) must include " +
                "a release that contains this version. Configured releases: " +
                ", ".join(release_dates),
            )

    # Create the toolchains hub repo
    python_toolchains(
        name = "python_interpreters",
        toolchains = toolchain_entries,
    )

    return _return_metadata(module_ctx, has_facts, new_facts, is_reproducible, resolved_latest)

def _find_asset(major_minor, platform, runtime_mode, release_dates, release_indices):
    """Find the best asset across releases, preferring newer releases."""
    for date in release_dates:
        index = release_indices.get(date, {})
        key = "{}/{}/{}".format(major_minor, platform, runtime_mode)
        entry = index.get(key)
        if entry:
            return {
                "release_date": date,
                "sha256": entry["sha256"],
                "filename": entry["filename"],
                "full_version": entry["full_version"],
            }
    return None

def _return_metadata(module_ctx, has_facts, facts, is_reproducible, resolved_latest):
    """Return extension_metadata with facts and reproducibility info."""
    if not has_facts or not hasattr(module_ctx, "extension_metadata"):
        return None

    if not is_reproducible:
        # Non-reproducible: "latest" was used. Signal this to Bazel so it
        # warns the user and doesn't cache the extension evaluation.
        # Include the resolved date in the reproducibility report.
        return module_ctx.extension_metadata(
            facts = facts,
            reproducible = False,
        )

    return module_ctx.extension_metadata(
        facts = facts,
        reproducible = True,
    )

_configure_tag = tag_class(
    attrs = {
        "base_url": attr.string(
            default = "",
            doc = """\
Base URL for downloading release assets. Defaults to the official PBS GitHub releases URL.
Override this to fetch from a mirror or fork, e.g.
"https://github.com/my-org/python-build-standalone/releases/download".
The URL should point to the directory containing release date directories,
such that {base_url}/{date}/SHA256SUMS is a valid path.

Only honored from the root module.
""",
        ),
        "releases": attr.string_list(
            mandatory = True,
            doc = """\
List of python-build-standalone release dates to search for interpreters,
e.g. ["20260303", "20241002"]. Newer releases are preferred when multiple
contain the same Python minor version.

The special value "latest" resolves to the newest release via the GitHub
releases API. This makes the extension non-reproducible: Bazel will
re-evaluate it on every invocation rather than caching the result.

See https://github.com/astral-sh/python-build-standalone/releases for
available releases.

Only honored from the root module. Non-root modules may include this tag
without error, but it will be silently ignored.
""",
        ),
    },
    doc = "Configure the set of python-build-standalone releases to search for interpreters.",
)

_toolchain_tag = tag_class(
    attrs = {
        "config_settings": attr.label_list(
            default = [],
            doc = """\
Additional config_setting labels that must match for this toolchain to be selected.
Use this to gate a toolchain on a custom flag, e.g.
["//:use_hermetic_python"]. The settings are added to the toolchain's
target_settings alongside the version and platform constraints.

Only honored from the root module.
""",
        ),
        "exec_compatible_with": attr.label_list(
            default = [],
            doc = """\
Additional exec platform constraints appended to each platform variant's
exec-tools registration. Target runtime and C toolchains do not run on the
execution platform.

Only honored from the root module.
""",
        ),
        "pre_release": attr.bool(
            default = False,
            doc = """\
Allow pre-release versions (alpha, beta, rc) for this toolchain.

By default, only final release versions are provisioned. Set this to True
to allow pre-release versions like 3.15.0a6 or 3.14.0b1. This is useful
for testing against upcoming Python versions that have no stable release yet.

Only honored from the root module.
""",
        ),
        "python_version": attr.string(
            mandatory = True,
            doc = """\
Python major.minor version to request, such as 3.11. The newest available patch
version is provisioned. Set pre_release to allow alpha, beta, or
release-candidate versions.
""",
        ),
        "target_compatible_with": attr.label_list(
            default = [],
            doc = """\
Additional target platform constraints appended to each platform variant's
target_compatible_with list.

Only honored from the root module.
""",
        ),
    },
)

python_interpreters = module_extension(
    implementation = _python_interpreters_impl,
    tag_classes = {
        "configure": _configure_tag,
        "toolchain": _toolchain_tag,
    },
)
