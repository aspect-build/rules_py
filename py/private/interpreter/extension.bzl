"""Module extension for provisioning Python interpreters from python-build-standalone."""

load(":repository.bzl", "python_interpreter", "python_toolchains")
load(":versions.bzl", "BUILD_CONFIGS", "DEFAULT_RELEASE_BASE_URL", "DEFAULT_RELEASE_DATES", "PLATFORMS")

# The GitHub API endpoint for resolving "latest" releases.
_GITHUB_API_LATEST = "https://api.github.com/repos/{owner}/{repo}/releases/latest"

def _sanitize(s):
    """Replace characters that are invalid in Bazel repo names."""
    return s.replace(".", "_").replace("-", "_")

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

        # Match against known build configs (check suffix + extension)
        remainder = filename[plus_idx + 1 + len(release_date) + 1:]  # skip "{date}-"
        matched_config = None
        matched_platform = None

        for config_name, config_info in BUILD_CONFIGS.items():
            expected_tail = "-{}.{}".format(config_info["suffix"], config_info["extension"])
            if remainder.endswith(expected_tail):
                platform_str = remainder[:len(remainder) - len(expected_tail)]
                if platform_str in PLATFORMS:
                    matched_config = config_name
                    matched_platform = platform_str
                    break

        if not matched_config:
            continue

        key = "{}/{}/{}".format(major_minor, matched_platform, matched_config)

        # Keep the newest patch version
        existing = index.get(key)
        if existing and not _version_gt(version, existing["full_version"]):
            continue

        index[key] = {
            "sha256": sha256,
            "filename": filename,
            "full_version": version,
        }

    return index

def _version_gt(a, b):
    """Returns True if version string a > b."""
    a_parts = a.split(".")
    b_parts = b.split(".")
    for i in range(max(len(a_parts), len(b_parts))):
        a_val = int(a_parts[i]) if i < len(a_parts) else 0
        b_val = int(b_parts[i]) if i < len(b_parts) else 0
        if a_val > b_val:
            return True
        if a_val < b_val:
            return False
    return False

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
    facts_key = "release_index_{}".format(release_date)
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

    # Collect release dates and base URLs from tags, falling back to defaults
    release_dates = []
    release_base_urls = {}  # date -> base_url
    has_release_tags = False

    for mod in module_ctx.modules:
        for tag in mod.tags.release:
            has_release_tags = True
            date = tag.date
            base_url = tag.base_url if tag.base_url else DEFAULT_RELEASE_BASE_URL

            if date == "latest":
                is_reproducible = False
                date = _resolve_latest(module_ctx, base_url)
                resolved_latest = date

            if date not in release_dates:
                release_dates.append(date)
                release_base_urls[date] = base_url

    if not has_release_tags:
        release_dates = list(DEFAULT_RELEASE_DATES)
        for date in release_dates:
            release_base_urls[date] = DEFAULT_RELEASE_BASE_URL

    # Sort newest-first for "prefer newest release" semantics
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
                toolchain_requests[key] = struct(
                    major_minor = major_minor,
                    build_config = build_config,
                )

    if not toolchain_requests:
        return _return_metadata(module_ctx, has_facts, facts, is_reproducible, resolved_latest)

    # If no default, pick the first one
    if not default_version:
        default_version = sorted(toolchain_requests.keys())[0][0]

    # Fetch and parse release indices (cached via facts)
    release_indices = {}
    new_facts = {}

    for date in release_dates:
        base_url = release_base_urls.get(date, DEFAULT_RELEASE_BASE_URL)
        index = _fetch_release_index(module_ctx, date, base_url, facts)
        release_indices[date] = index

        # Cache in facts for next run — but never cache under "latest"
        facts_key = "release_index_{}".format(date)
        new_facts[facts_key] = index

    # Order: default version first, then sorted
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

            # Find the best release for this version/platform/config
            asset_info = _find_asset(
                req.major_minor,
                platform_triple,
                req.build_config,
                release_dates,
                release_indices,
            )

            if asset_info:
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
                    strip_prefix = BUILD_CONFIGS[req.build_config]["strip_prefix"],
                    freethreaded = BUILD_CONFIGS[req.build_config]["freethreaded"],
                )
            else:
                # Version/platform combo doesn't exist in any release
                python_interpreter(
                    name = repo_name,
                    python_version = "",
                    platform = platform_triple,
                    url = "",
                    sha256 = "",
                    strip_prefix = "",
                    freethreaded = False,
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

_release_tag = tag_class(
    attrs = {
        "base_url": attr.string(
            default = "",
            doc = """\
Base URL for downloading release assets. Defaults to the official PBS GitHub releases URL.
Override this to fetch from a mirror or fork, e.g.
"https://github.com/my-org/python-build-standalone/releases/download".
The URL should point to the directory containing release date directories,
such that {base_url}/{date}/SHA256SUMS is a valid path.
""",
        ),
        "date": attr.string(mandatory = True, doc = """\
A python-build-standalone release date (e.g. "20251209") or "latest".

Using "latest" resolves to the newest release via the GitHub releases API.
This makes the extension non-reproducible: Bazel will re-evaluate it on
every invocation rather than caching the result.

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
