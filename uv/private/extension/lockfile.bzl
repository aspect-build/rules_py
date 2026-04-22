"""Transformers for a parsed `uv.lock` file.

Converts the dictionary produced by the TOML parser into the internal data
structures that `aspect_rules_py` consumes: normalized dependency graphs,
platform configuration maps, and artifact tables for wheels and source
distributions.
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load(":git_utils.bzl", "parse_git_url", "try_git_to_http_archive")

def normalize_deps(lock_id, lock_data):
    """Normalizes dependency specifications in a lockfile.

    Computes a default version for each package that appears exactly once, then
    backfills any dependency entries that omit a version. Also normalizes all
    package and dependency names and ensures that every sdist entry carries a
    `url` field.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A tuple `(default_versions, package_versions, lock_data)` where:
        - `default_versions` maps a package name to a dependency tuple
          `(lock_id, package_name, version, "__base__")`.
        - `package_versions` maps a package name to a dict of its versions.
        - `lock_data` is the mutated lockfile dictionary.
    """
    package_versions = {}
    for spec in lock_data.get("package", []):
        if type(spec) != "dict" or not spec.get("name") or not spec.get("version"):
            return None, None, None
        spec["name"] = normalize_name(spec["name"])
        package_versions.setdefault(spec["name"], {})[spec["version"]] = 1

    default_versions = {
        requirement: (lock_id, requirement, list(versions.keys())[0], "__base__")
        for requirement, versions in package_versions.items()
        if len(versions) == 1
    }

    def _fix_version(dep):
        dep["name"] = normalize_name(dep["name"])
        if not "version" in dep:
            dv = default_versions.get(dep["name"])
            if dv == None:
                return False
            dep["version"] = dv[2]
        return True

    for spec in lock_data.get("package", []):
        if "sdist" in spec and not "url" in spec["sdist"]:
            if not spec.get("source") or not spec["source"].get("url"):
                return None, None, None
            spec["sdist"]["url"] = spec["source"]["url"]

        for dep in spec.get("dependencies", []):
            if not _fix_version(dep):
                return None, None, None

        for extra_deps in spec.get("optional-dependencies", {}).values():
            for dep in extra_deps:
                if not _fix_version(dep):
                    return None, None, None

    return default_versions, package_versions, lock_data

def _platform_tag_matches_target(target, platform_tag):
    """Determines whether a wheel platform tag satisfies a canonical target.

    Args:
        target: A canonical target platform string (e.g. "linux_aarch64").
        platform_tag: A wheel platform tag (e.g. "manylinux_2_17_x86_64").

    Returns:
        True if the wheel platform tag is compatible with the target.
    """
    if platform_tag == "any":
        return True
    if target == "linux_aarch64":
        return (platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_")) and platform_tag.endswith("_aarch64")
    if target == "linux_x86_64":
        return (platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_")) and platform_tag.endswith("_x86_64")
    if target == "linux_armv7l":
        return (platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_")) and platform_tag.endswith("_armv7l")
    if target == "linux_ppc64le":
        return (platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_")) and platform_tag.endswith("_ppc64le")
    if target == "linux_s390x":
        return (platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_")) and platform_tag.endswith("_s390x")
    if target == "linux_riscv64":
        return (platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_")) and platform_tag.endswith("_riscv64")
    if target == "macos_aarch64":
        return platform_tag.startswith("macosx_") and ("arm64" in platform_tag or "universal2" in platform_tag)
    if target == "macos_x86_64":
        return platform_tag.startswith("macosx_") and ("x86_64" in platform_tag or "universal2" in platform_tag)
    if target == "windows_x86_64":
        return platform_tag in ["win_amd64"]
    if target == "windows_arm64":
        return platform_tag in ["win_arm64"]
    return False

def wheel_matches_any_target(wheel_name, target_platforms):
    """Checks if a wheel filename matches any of the target platforms.

    Args:
        wheel_name: The filename of the wheel (e.g. "numpy-1.24.3-...-manylinux_2_17_x86_64.whl").
        target_platforms: A list of canonical target platform strings.

    Returns:
        True if at least one target platform matches the wheel.
    """
    if not target_platforms:
        return True
    parsed = parse_whl_name(wheel_name)
    for platform_tag in parsed.platform_tags:
        for target in target_platforms:
            if _platform_tag_matches_target(target, platform_tag):
                return True
    return False

MAGIC_ACTIVATE_BASE_MARKER = "magic_activate_base == 1"

def build_marker_graph(lock_id, lock_data):
    """Builds a dependency graph from a lockfile.

    Nodes are dependency tuples `(lock_id, package, version, extra)`. Edges are
    annotated with PEP 508 marker strings. Dependencies without an explicit
    extra are mapped to the synthetic `__base__` extra, and every extra node
    implicitly depends on the `__base__` node of the same package.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary representing the dependency graph. Each key is a node tuple
        and each value is a dict mapping destination nodes to a dict of markers.
    """
    graph = {}
    for spec in lock_data.get("package", []):
        k = (lock_id, spec["name"], spec["version"], "__base__")
        graph.setdefault(k, {})
        for dep in spec.get("dependencies", []):
            extras = dep.get("extra", ["__base__"])
            if "__base__" not in extras:
                extras = ["__base__"] + extras

            for e in extras:
                ek = (lock_id, dep["name"], dep["version"], e)
                graph[k].setdefault(ek, {})
                graph[k][ek][dep.get("marker", "")] = 1

        for extra_name, optional_deps in spec.get("optional-dependencies", {}).items():
            ek = (lock_id, spec["name"], spec["version"], extra_name)
            graph.setdefault(ek, {})
            for dep in optional_deps:
                extras = dep.get("extra", ["__base__"])
                if "__base__" not in extras:
                    extras = ["__base__"] + extras

                for e in extras:
                    eek = (lock_id, dep["name"], dep["version"], e)
                    graph[ek].setdefault(eek, {})
                    graph[ek][eek][dep.get("marker", "")] = 1

    return graph

def collect_configurations(lock, target_platforms = []):
    """Collects all unique platform configurations from the wheels in a lockfile.

    Parses every wheel filename to extract Python, platform and ABI tags, filters
    out unsupported tags and wheels that do not match the requested target
    platforms, and maps each surviving combination to a list of `config_setting`
    labels.

    Args:
        lock: The parsed content of the `uv.lock` file.
        target_platforms: Optional list of canonical target platform strings.
            When provided, only wheels matching at least one target platform are
            considered.

    Returns:
        A dictionary mapping configuration strings (e.g.
        "cp39-manylinux_2_17_x86_64-cp39") to a list of `config_setting`
        labels that define the configuration.
    """
    wheel_files = {}
    for package in lock.get("package", []):
        for whl in package.get("wheels", []):
            url = whl["url"]
            wheel_name = url.split("/")[-1]
            if target_platforms and not wheel_matches_any_target(wheel_name, target_platforms):
                continue
            wheel_files[wheel_name] = 1

    configurations = {}
    for wheel_name in wheel_files.keys():
        parsed_wheel = parse_whl_name(wheel_name)
        for python_tag in parsed_wheel.python_tags:
            if not supported_python(python_tag):
                continue

            for platform_tag in parsed_wheel.platform_tags:
                if not supported_platform(platform_tag):
                    continue

                for abi_tag in parsed_wheel.abi_tags:
                    configuration = "{}-{}-{}".format(python_tag, platform_tag, abi_tag)
                    configurations[configuration] = [
                        "@aspect_rules_py//uv/private/constraints/platform:{}".format(platform_tag),
                        "@aspect_rules_py//uv/private/constraints/abi:{}".format(abi_tag),
                        "@aspect_rules_py//uv/private/constraints/python:{}".format(python_tag),
                    ]

    return configurations

def collect_bdists(lock_data, target_platforms = []):
    """Collects all pre-built wheels (bdists) from a lockfile.

    Args:
        lock_data: The parsed content of the `uv.lock` file.
        target_platforms: Optional list of canonical target platform strings.
            When provided, only wheels matching at least one target platform are
            collected.

    Returns:
        A tuple `(bdist_specs, bdist_table)` where:
        - `bdist_specs` maps a generated repository name to the wheel
          specification dict.
        - `bdist_table` maps the wheel hash to a Bazel label
          `@repo_name//file`.
    """
    bdist_specs = {}
    bdist_table = {}
    for package in lock_data.get("package", []):
        for bdist in package.get("wheels", []):
            wheel_name = bdist["url"].split("/")[-1]
            if target_platforms and not wheel_matches_any_target(wheel_name, target_platforms):
                continue
            identifier = None
            if "hash" in bdist:
                identifier = bdist["hash"].split(":")[1][:16]
            else:
                identifier = sha1(bdist["url"])[:16]

            bdist_repo_name = "whl__{}__{}".format(package["name"], identifier)
            bdist_specs[bdist_repo_name] = bdist
            bdist_table[bdist["hash"]] = "@{}//file".format(bdist_repo_name)

    return bdist_specs, bdist_table

def collect_sdists(
        lock_id,
        lock_data,
        allow_git_to_http_conversion = True):
    """Collects all source distributions (sdists) from a lockfile.

    Handles both regular sdists and git-based sources. For git sources, attempts
    to convert the git checkout into an HTTP archive when permitted.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.
        allow_git_to_http_conversion: Whether to attempt converting git URLs
            into HTTP archive downloads.

    Returns:
        A tuple `(sdist_specs, sdist_table)` where:
        - `sdist_specs` maps a generated repository name to a specification
          dict with either a `"file"` or `"git"` entry.
        - `sdist_table` maps an sdist build key to a Bazel label
          `@repo_name//file`.
    """
    sdist_specs = {}
    sdist_table = {}
    for package in lock_data.get("package", []):
        k = "sdist_build__{}__{}__{}".format(lock_id, package["name"], package["version"].replace(".", "_"))
        if "sdist" in package:
            sdist = package["sdist"]

            identifier = None
            if "hash" in sdist:
                identifier = sdist["hash"].split(":")[1][:16]
            else:
                identifier = sha1(sdist["url"])[:16]

            sdist_repo_name = "sdist__{}__{}".format(package["name"], identifier)
            sdist_specs[sdist_repo_name] = {"file": sdist}
            sdist_table[k] = "@{}//file".format(sdist_repo_name)

        elif "git" in package["source"]:
            git_url = package["source"]["git"]
            git_cfg = parse_git_url(git_url)
            sdist_repo_name = "sdist_git__{}__{}".format(package["name"], sha1(git_url)[:16])

            sdist_table[k] = "@{}//file".format(sdist_repo_name)
            sdist_cfg = try_git_to_http_archive(git_cfg)
            if allow_git_to_http_conversion and sdist_cfg:
                sdist_specs[sdist_repo_name] = {"file": sdist_cfg}
            else:
                sdist_specs[sdist_repo_name] = {"git": git_cfg}

    return sdist_specs, sdist_table

def collect_markers(graph):
    """Collects all unique marker expressions from the dependency graph.

    Args:
        graph: The dependency graph.

    Returns:
        A dictionary mapping each unique marker expression string to its SHA-1
        hash.
    """
    acc = {}
    for _dep, nexts in graph.items():
        for _next, markers in nexts.items():
            for marker in markers.keys():
                if marker and marker not in acc:
                    acc[marker] = sha1(marker)

    return acc
