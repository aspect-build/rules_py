"""PBS release-index parsing and asset selection."""

load(":version_util.bzl", "version_gt")
load(":versions.bzl", "BUILD_CONFIGS", "PLATFORMS")

def parse_sha256sums(content, release_date):
    """Parse configured CPython assets from a PBS SHA256SUMS file.

    Returns a dict mapping (major_minor, platform, build_config) to every full
    version published in the release. Each version maps to its filename and
    checksum.
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
        versions = index.get(key)
        if versions == None:
            versions = {}
            index[key] = versions
        if version in versions:
            continue
        versions[version] = {
            "sha256": sha256,
            "filename": filename,
        }

    return index

def find_asset(major_minor, platform, build_config, release_dates, release_indices):
    """Select the newest asset from the first release containing the key."""
    key = "{}/{}/{}".format(major_minor, platform, build_config)
    for release_date in release_dates:
        versions = release_indices.get(release_date, {}).get(key, {})
        selected_version = None
        for full_version in versions:
            if selected_version == None or version_gt(full_version, selected_version):
                selected_version = full_version
        if selected_version != None:
            return dict(
                versions[selected_version],
                full_version = selected_version,
                release_date = release_date,
            )
    return None
