"""Module extension for provisioning Python interpreters from python-build-standalone."""

load(":repository.bzl", "python_interpreter", "python_toolchains")
load(":version_util.bzl", "is_pre_release", "is_valid_python_tag", "is_valid_python_version", "version_gt")
load(":versions.bzl", "BUILD_CONFIGS", "DEFAULT_RELEASE_BASE_URL", "DEFAULT_RELEASE_DATES", "PLATFORMS")

# The GitHub API endpoint for resolving "latest" releases.
_GITHUB_API_LATEST = "https://api.github.com/repos/{owner}/{repo}/releases/latest"

# Facts can outlive an extension implementation change, so matching changes
# must use a new key rather than accepting the old index shape.
_RELEASE_INDEX_SCHEMA = 1

def _sanitize(s):
    """Replace characters that are invalid in Bazel repo names."""
    return s.replace(".", "_").replace("-", "_").replace("+", "_")

def _parse_sha256sums(content, release_date):
    """Parse a SHA256SUMS file into a structured index.

    Returns a dict mapping (major_minor, platform, build_config) -> {
        "sha256": str,
        "filename": str,
        "full_version": str,
    }

    When multiple patch versions exist for the same major.minor, only the
    newest is kept.
    """
    index = {}
    seen_assets = {}
    asset_matchers = {}

    config_names = sorted(BUILD_CONFIGS.keys())
    for platform, platform_info in PLATFORMS.items():
        asset_suffixes = platform_info.get("asset_suffixes", {})
        if sorted(asset_suffixes.keys()) != config_names:
            fail(
                "PBS platform {} must define exactly these logical build configs: {}; got {}".format(
                    platform,
                    config_names,
                    sorted(asset_suffixes.keys()),
                ),
            )

        for config_name, config_info in BUILD_CONFIGS.items():
            suffix = asset_suffixes[config_name]
            if not suffix:
                fail("PBS platform {} has an empty asset suffix for {}".format(platform, config_name))
            asset_tail = "{}-{}.{}".format(platform, suffix, config_info["extension"])
            if asset_tail in asset_matchers:
                other = asset_matchers[asset_tail]
                fail(
                    "Ambiguous PBS asset matcher {} for {}/{} and {}/{}".format(
                        asset_tail,
                        other[0],
                        other[1],
                        platform,
                        config_name,
                    ),
                )
            asset_matchers[asset_tail] = (platform, config_name)

    for line_number, raw_line in enumerate(content.split("\n")):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        parts = [part for part in line.replace("\t", " ").split(" ") if part]
        if len(parts) != 2:
            for asset_tail in asset_matchers:
                if line.endswith("-" + asset_tail):
                    fail(
                        "Malformed configured PBS asset on line {} of release {}: {}".format(
                            line_number + 1,
                            release_date,
                            line,
                        ),
                    )
            continue

        sha256 = parts[0].strip()
        filename = parts[1].strip()
        if filename.startswith("*"):
            filename = filename[1:]

        if not filename.startswith("cpython-"):
            continue

        matches = []
        for asset_tail, matcher in asset_matchers.items():
            if filename.endswith("-" + asset_tail):
                matches.append((asset_tail, matcher))

        if not matches:
            continue
        if len(matches) != 1:
            fail(
                "Ambiguous configured PBS asset on line {} of release {}: {} matches {}".format(
                    line_number + 1,
                    release_date,
                    filename,
                    [match[0] for match in matches],
                ),
            )

        asset_tail, (matched_platform, matched_config) = matches[0]

        # Parse exactly: cpython-{version}+{date}-{platform}-{suffix}.{ext}
        plus_idx = filename.find("+")
        expected_remainder = "{}-{}".format(release_date, asset_tail)
        if plus_idx < len("cpython-") or filename[plus_idx + 1:] != expected_remainder:
            fail(
                "Malformed configured PBS asset on line {} of release {}: expected cpython-{{version}}+{}, got {}".format(
                    line_number + 1,
                    release_date,
                    expected_remainder,
                    filename,
                ),
            )
        version = filename[len("cpython-"):plus_idx]

        if not is_valid_python_version(version):
            fail(
                "Malformed Python version '{}' in configured PBS asset on line {} of release {}: {}".format(
                    version,
                    line_number + 1,
                    release_date,
                    filename,
                ),
            )
        version_parts = version.split(".")
        major_minor = "{}.{}".format(version_parts[0], version_parts[1])

        valid_sha256 = len(sha256) == 64
        for char in sha256.elems():
            if char not in "0123456789abcdefABCDEF":
                valid_sha256 = False
        if not valid_sha256:
            fail(
                "Malformed SHA256 for configured PBS asset on line {} of release {}: {}".format(
                    line_number + 1,
                    release_date,
                    line,
                ),
            )
        sha256 = sha256.lower()

        key = "{}/{}/{}".format(major_minor, matched_platform, matched_config)
        version_key = (key, version)
        prior_asset = seen_assets.get(version_key)
        if prior_asset:
            if filename == prior_asset["filename"] and sha256 == prior_asset["sha256"]:
                continue
            fail(
                "Ambiguous PBS assets for {} in release {}: {} and {}".format(
                    key,
                    release_date,
                    prior_asset["filename"],
                    filename,
                ),
            )
        seen_assets[version_key] = {
            "filename": filename,
            "sha256": sha256,
        }

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
                    "Only one root-module interpreters.configure() tag is allowed. " +
                    "Pass all release dates as a single list.",
                )
            has_configure = True
            base_url = tag.base_url if tag.base_url else DEFAULT_RELEASE_BASE_URL
            for date in tag.releases:
                if date == "latest":
                    is_reproducible = False
                    date = _resolve_latest(module_ctx, base_url)
                    resolved_latest = date
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
    # but only the root module's default, pre-release policy, and toolchain
    # settings are honored.
    requested_versions = []
    version_sources = {}  # major_minor -> list of module names (for error messages)
    allow_pre_release = {}  # major_minor -> bool
    root_settings = {}  # major_minor -> root-owned toolchain settings
    root_versions = {}  # major_minor -> True
    explicit_defaults = {}

    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            version = tag.python_version

            # Normalize: "3.11.14" -> major_minor "3.11"
            if not is_valid_python_tag(version):
                fail(
                    "python_version must be major.minor or a final, alpha, beta, " +
                    "or release-candidate version, got '{}'".format(version),
                )
            parts = version.split(".")
            major_minor = "{}.{}".format(parts[0], parts[1])

            if mod.is_root:
                root_versions[major_minor] = True
                if tag.is_default:
                    explicit_defaults[major_minor] = True
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
                        "Tags whose python_version values normalize to the same major.minor " +
                        "must use identical config_settings, target_compatible_with, and " +
                        "exec_compatible_with.",
                    )
                root_settings[major_minor] = settings

            if major_minor not in requested_versions:
                requested_versions.append(major_minor)
                version_sources[major_minor] = []
            version_sources[major_minor].append(mod.name)

            # Pre-release policy is root-module-only. A non-root module
            # requesting "3.15.0a2" will need the root to also allow
            # pre-releases for that version.
            if mod.is_root and (tag.pre_release or is_pre_release(version)):
                allow_pre_release[major_minor] = True
            elif major_minor not in allow_pre_release:
                allow_pre_release[major_minor] = False

    if len(explicit_defaults) > 1:
        fail(
            "Multiple root interpreters.toolchain() tags set is_default = True: {}. ".format(
                ", ".join(sorted(explicit_defaults.keys())),
            ) +
            "Exactly one distinct default version is allowed.",
        )

    default_version = sorted(explicit_defaults.keys())[0] if explicit_defaults else ""
    if len(root_versions) == 1 and not default_version:
        default_version = root_versions.keys()[0]
    elif len(root_versions) > 1 and not default_version:
        fail(
            "Multiple Python versions were requested by the root module: {}. ".format(
                ", ".join(sorted(root_versions.keys())),
            ) +
            "Set is_default = True on exactly one root interpreters.toolchain() tag.",
        )

    if not requested_versions:
        return _return_metadata(module_ctx, has_facts, facts, is_reproducible, resolved_latest)

    new_facts = {}

    # Fetch and parse release indices (cached via facts)
    release_indices = {}

    for date in release_dates:
        base_url = release_base_urls.get(date, DEFAULT_RELEASE_BASE_URL)
        index = _fetch_release_index(module_ctx, date, base_url, facts)
        release_indices[date] = index

        # Cache in facts for next run — but never cache under "latest"
        facts_key = _release_index_facts_key(date, base_url)
        new_facts[facts_key] = index

    # Create per-platform, per-build-config interpreter repos and collect
    # toolchain entries.
    toolchain_entries = []

    for major_minor in sorted(requested_versions):
        version_found = False
        settings = root_settings.get(major_minor, {
            "config_settings": [],
            "exec_compatible_with": [],
            "target_compatible_with": [],
        })
        for config_name, config_info in BUILD_CONFIGS.items():
            for platform_triple, platform_info in PLATFORMS.items():
                repo_name = "python_{}_{}".format(
                    _sanitize(major_minor),
                    _sanitize(platform_triple),
                )
                if config_name != "install_only":
                    repo_name += "_" + _sanitize(config_name)

                # Find the best release for this version/platform/config
                asset_info = _find_asset(
                    major_minor,
                    platform_triple,
                    config_name,
                    release_dates,
                    release_indices,
                )

                if not asset_info:
                    # Version/platform/config combo doesn't exist — skip it
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
                    python_version = asset_info["full_version"],
                    platform = platform_triple,
                    url = url,
                    sha256 = asset_info["sha256"],
                    strip_prefix = config_info["strip_prefix"],
                    freethreaded = config_info["freethreaded"],
                )

                toolchain_entries.append(json.encode({
                    "name": repo_name,
                    "repo": repo_name,
                    "py_cc_toolchain": "@{}//:py_cc_toolchain".format(repo_name),
                    "python_version": major_minor,
                    "freethreaded": config_info["freethreaded"],
                    "compatible_with": platform_info["compatible_with"],
                    "register_exec_tools": platform_info["register_exec_tools"],
                    "platform_target_settings": platform_info.get("target_settings", {}),
                    "config_settings": settings["config_settings"],
                    "target_compatible_with": settings["target_compatible_with"],
                    "exec_compatible_with": settings["exec_compatible_with"],
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
        default_python_version = default_version,
        toolchains = toolchain_entries,
    )

    return _return_metadata(module_ctx, has_facts, new_facts, is_reproducible, resolved_latest)

def _find_asset(major_minor, platform, build_config, release_dates, release_indices):
    """Find the best asset across releases, preferring newer releases."""
    for date in release_dates:
        index = release_indices.get(date, {})
        key = "{}/{}/{}".format(major_minor, platform, build_config)
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
Additional config_setting labels that must match for this Python version's
runtime, C, and exec-tools registrations. Use this to gate a toolchain on a
custom flag, e.g. ["//:use_hermetic_python"]. The settings are added to each
registration's target_settings alongside the version and free-threaded mode.
Platform-specific target settings apply only to the runtime and C
registrations.

Only honored from the root module.
""",
        ),
        "exec_compatible_with": attr.label_list(
            default = [],
            doc = """\
Additional exec platform constraints appended to each platform variant's
exec_compatible_with list.

Only honored from the root module.
""",
        ),
        "is_default": attr.bool(
            default = False,
            doc = """\
Select this Python version when no target attribute or command-line flag does.

Only honored from the root module. A single distinct version requested by the
root is implicitly the default. If the root requests multiple distinct
versions, exactly one tag must set is_default = True.
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
            doc = "Python version to provision as major.minor or a full final/a/b/rc version. The newest available patch version is used.",
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
