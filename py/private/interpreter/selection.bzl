"""Pure PBS release-index parsing and interpreter cohort selection."""

load(":version_util.bzl", "is_pre_release", "is_valid_python_version", "version_gt")
load(":versions.bzl", "BUILD_CONFIGS", "PLATFORMS")

def _sanitize(value):
    return value.replace(".", "_").replace("-", "_").replace("+", "_")

def _target_repo_name(major_minor, platform, build_config):
    name = "python_{}_{}".format(_sanitize(major_minor), _sanitize(platform))
    if build_config != "install_only":
        name += "_" + _sanitize(build_config)
    return name

def _asset_key(release_date, full_version, platform, build_config):
    return "{}/{}/{}/{}".format(release_date, full_version, platform, build_config)

def parse_sha256sums(content, release_date):
    """Parse all configured CPython assets from a PBS SHA256SUMS file."""
    index = {}
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
        full_version = filename[len("cpython-"):plus_idx]
        if not is_valid_python_version(full_version):
            fail(
                "Malformed Python version '{}' in configured PBS asset on line {} of release {}: {}".format(
                    full_version,
                    line_number + 1,
                    release_date,
                    filename,
                ),
            )

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

        version_parts = full_version.split(".")
        major_minor = "{}.{}".format(version_parts[0], version_parts[1])
        key = "{}/{}/{}".format(major_minor, matched_platform, matched_config)
        versions = index.get(key)
        if versions == None:
            versions = {}
            index[key] = versions
        prior_asset = versions.get(full_version)
        if prior_asset:
            if filename == prior_asset["filename"] and sha256 == prior_asset["sha256"]:
                continue
            fail(
                "Ambiguous PBS assets for {} version {} in release {}: {} and {}".format(
                    key,
                    full_version,
                    release_date,
                    prior_asset["filename"],
                    filename,
                ),
            )
        versions[full_version] = {
            "filename": filename,
            "sha256": sha256,
        }

    return index

def find_asset(major_minor, platform, build_config, release_dates, release_indices):
    """Find the newest asset in the first configured release containing one."""
    key = "{}/{}/{}".format(major_minor, platform, build_config)
    for release_date in release_dates:
        versions = release_indices.get(release_date, {}).get(key, {})
        selected_version = None
        for full_version in versions:
            if selected_version == None or version_gt(full_version, selected_version):
                selected_version = full_version
        if selected_version != None:
            asset = versions[selected_version]
            return dict(asset, release_date = release_date, full_version = selected_version)
    return None

def build_toolchain_plan(
        major_minor,
        release_dates,
        release_indices,
        platforms,
        build_configs,
        allow_pre_release,
        settings):
    """Select target assets, exact exec companions, and repositories."""
    targets = []
    execs = []
    repositories = []
    repository_names = {}
    repo_by_asset = {}
    cohorts = {}
    cohort_order = []

    for build_config, config_info in build_configs.items():
        for platform, platform_info in platforms.items():
            asset = find_asset(
                major_minor,
                platform,
                build_config,
                release_dates,
                release_indices,
            )
            if asset == None:
                continue
            if is_pre_release(asset["full_version"]) and not allow_pre_release:
                continue

            repo_name = _target_repo_name(major_minor, platform, build_config)
            repository = dict(
                asset,
                build_config = build_config,
                freethreaded = config_info["freethreaded"],
                name = repo_name,
                platform = platform,
                strip_prefix = config_info["strip_prefix"],
            )
            asset_key = _asset_key(
                asset["release_date"],
                asset["full_version"],
                platform,
                build_config,
            )
            prior_asset_key = repository_names.get(repo_name)
            if prior_asset_key != None and prior_asset_key != asset_key:
                fail("Repository name {} identifies both {} and {}".format(
                    repo_name,
                    prior_asset_key,
                    asset_key,
                ))
            repositories.append(repository)
            repository_names[repo_name] = asset_key
            repo_by_asset[asset_key] = repo_name

            # CPython changed bytecode magic between 3.15.0a1 and 3.15.0a2:
            # https://github.com/python/cpython/blob/v3.15.0a1/Include/internal/pycore_magic_number.h
            # https://github.com/python/cpython/blob/v3.15.0a2/Include/internal/pycore_magic_number.h
            # Exact release/version matching is the conservative proxy because
            # PyRuntimeInfo does not expose bytecode magic.
            cohort_name = "cohort_{}_{}_{}_{}".format(
                _sanitize(major_minor),
                _sanitize(asset["release_date"]),
                _sanitize(asset["full_version"]),
                _sanitize(build_config),
            )
            cohort = cohorts.get(cohort_name)
            if cohort == None:
                cohort = {
                    "build_config": build_config,
                    "freethreaded": config_info["freethreaded"],
                    "full_version": asset["full_version"],
                    "name": cohort_name,
                    "release_date": asset["release_date"],
                    "target_platforms": [],
                }
                cohorts[cohort_name] = cohort
                cohort_order.append(cohort_name)
            elif (
                cohort["build_config"] != build_config or
                cohort["full_version"] != asset["full_version"] or
                cohort["release_date"] != asset["release_date"]
            ):
                fail("Cohort name {} identifies multiple PBS assets".format(cohort_name))
            cohort["target_platforms"].append(platform)

            targets.append({
                "compatible_with": platform_info["compatible_with"],
                "config_settings": settings["config_settings"],
                "freethreaded": config_info["freethreaded"],
                "name": repo_name,
                "platform": platform,
                "platform_target_settings": platform_info.get("target_settings", {}),
                "py_cc_toolchain": "@{}//:py_cc_toolchain".format(repo_name),
                "python_version": major_minor,
                "repo": repo_name,
                "target_compatible_with": settings["target_compatible_with"],
            })

    for cohort_name in cohort_order:
        cohort = cohorts[cohort_name]
        for platform, platform_info in platforms.items():
            if not platform_info["register_exec_tools"]:
                continue
            key = "{}/{}/{}".format(major_minor, platform, cohort["build_config"])
            exact_asset = release_indices.get(cohort["release_date"], {}).get(key, {}).get(cohort["full_version"])
            if exact_asset == None:
                continue
            asset = dict(
                exact_asset,
                release_date = cohort["release_date"],
                full_version = cohort["full_version"],
            )

            asset_key = _asset_key(
                cohort["release_date"],
                cohort["full_version"],
                platform,
                cohort["build_config"],
            )
            repo_name = repo_by_asset.get(asset_key)
            if repo_name == None:
                repo_name = "{}_cohort_{}_{}".format(
                    _target_repo_name(major_minor, platform, cohort["build_config"]),
                    _sanitize(cohort["release_date"]),
                    _sanitize(cohort["full_version"]),
                )
                prior_asset_key = repository_names.get(repo_name)
                if prior_asset_key != None and prior_asset_key != asset_key:
                    fail("Repository name {} identifies both {} and {}".format(
                        repo_name,
                        prior_asset_key,
                        asset_key,
                    ))
                if prior_asset_key == None:
                    repositories.append(dict(
                        asset,
                        build_config = cohort["build_config"],
                        freethreaded = cohort["freethreaded"],
                        name = repo_name,
                        platform = platform,
                        strip_prefix = build_configs[cohort["build_config"]]["strip_prefix"],
                    ))
                    repository_names[repo_name] = asset_key
                repo_by_asset[asset_key] = repo_name

            execs.append({
                "cohort": cohort_name,
                "compatible_with": platform_info["compatible_with"],
                "config_settings": settings["config_settings"],
                "exec_compatible_with": settings["exec_compatible_with"],
                "freethreaded": cohort["freethreaded"],
                "name": "{}_on_{}".format(cohort_name, _sanitize(platform)),
                "python_version": major_minor,
                "repo": repo_name,
                "target_compatible_with": settings["target_compatible_with"],
                "target_platforms": cohort["target_platforms"],
            })

    return {
        "execs": execs,
        "repositories": repositories,
        "targets": targets,
    }
