"""
Machinery specific to interacting with a uv.lock
"""

load("@bazel_lib//lib:strings.bzl", "ord")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private:normalize_version.bzl", "normalize_version")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load("//uv/private/whl_install:repository.bzl", "compatible_python_tags")
load(":git_utils.bzl", "locked_git_requirement_urls", "parse_git_url", "try_git_to_http_archive")
load(":marker_simplify.bzl", "simplify_extra_marker")

def _local_file_url(local_path, lockfile_directory):
    """Convert a uv lockfile-relative source path into uv's canonical file URL.

    Mirrors `VerbatimUrl::from_path -> DisplaySafeUrl::from_file_path ->
    Url::from_file_path` in uv-pep508 and rust-url. Encode Starlark's UTF-8
    bytes with rust-url's WHATWG `SPECIAL_PATH_SEGMENT` and `PATH_SEGMENT`
    rules while retaining path separators and Windows drive or UNC prefixes.
    Existing `file://` URLs are already canonical and remain unchanged.

    Args:
        local_path: A local source path or existing `file://` URL.
        lockfile_directory: The absolute directory containing the uv lockfile.

    Returns:
        The absolute, percent-encoded `file://` URL used by uv.
    """
    if local_path.startswith("file://"):
        return local_path

    windows_path = (
        local_path.startswith("\\\\") or
        (len(local_path) > 2 and local_path[1] == ":") or
        lockfile_directory.startswith("\\\\") or
        (len(lockfile_directory) > 2 and lockfile_directory[1] == ":")
    )
    if windows_path:
        local_path = local_path.replace("\\", "/")
        lockfile_directory = lockfile_directory.replace("\\", "/")

    if not paths.is_absolute(local_path):
        local_path = paths.join(lockfile_directory, local_path)

    normalized_path = paths.normalize(local_path)
    if not windows_path and normalized_path.startswith("//"):
        normalized_path = "/" + normalized_path.lstrip("/")

    hex_digits = "0123456789ABCDEF"
    encoded_path = []
    for char in normalized_path.elems():
        byte = ord(char)
        if byte < 0x20 or byte >= 0x7F or char in " \"#%<>?`{}\\":
            encoded_path.append("%" + hex_digits[byte // 16] + hex_digits[byte % 16])
        else:
            encoded_path.append(char)

    if normalized_path.startswith("//"):
        return "file:" + "".join(encoded_path)
    if len(normalized_path) > 2 and normalized_path[1] == ":":
        return "file:///" + "".join(encoded_path)
    return "file://" + "".join(encoded_path)

def collect_locked_requirement_urls(lock_id, lock_data, lockfile_directory):
    """Index locked artifact, Git, and local-source direct references."""
    locked_urls = {}

    for package in lock_data.get("package", []):
        package_name = normalize_name(package["name"])
        dependency = (lock_id, package_name, package["version"], "__base__")
        source = package.get("source", {})

        for artifact in package.get("wheels", []) + [package.get("sdist", {}), source]:
            url = artifact.get("url")
            if url:
                locked_urls[(package_name, url)] = dependency

        git = source.get("git")
        if git:
            for url in locked_git_requirement_urls(git):
                locked_urls[(package_name, url)] = dependency

        for source_kind in ("path", "directory", "editable"):
            local_path = source.get(source_kind)
            if local_path:
                url = _local_file_url(local_path, lockfile_directory)
                locked_urls[(package_name, url)] = dependency

    return locked_urls

def url_basename(url):
    """Returns the trailing file name of a distribution URL.

    Lockfile wheel and sdist URLs name the distribution file in the last path
    segment, but registries may append a query string (e.g. signed/expiring
    download links) and/or a fragment (e.g. PEP 503 `#sha256=...` hashes).
    Neither is part of the file name, so both are stripped.

    Args:
        url: str, the URL of a distribution file.

    Returns:
        the file name as a string, e.g. "foo-1.0.0-py3-none-any.whl".
    """
    basename = url.split("/")[-1].split("?")[0].split("#")[0]
    if not basename:
        fail("Invalid distribution URL (no file name): " + url)
    return basename

def _dist_identifier(dist):
    """Stable short id for a wheel/sdist repo name.

    Lockfile sources without a `hash` field (e.g. find-links registries)
    fall back to hashing the URL, the only field guaranteed present.
    """
    if "hash" in dist:
        return dist["hash"].split(":")[1][:16]
    return sha1(dist["url"])[:16]

def normalize_deps(lock_id, lock_data, lockfile_directory):
    """Normalizes dependency specifications in a lockfile.

    This function performs two main normalization steps:
    1.  It computes a "default version" for each package, which is used when a
        dependency specification does not include a version. The default version
        is only computed for packages that have a single version in the lockfile.
    2.  It updates all dependency statements within the lockfile to be
        version-disambiguated, using the default versions where necessary.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.
        lockfile_directory: Absolute directory containing the lockfile.

    Returns:
        A tuple containing:
        - A dictionary mapping package names to their default version dependency
          tuples `(lock_id, package_name, version, "__base__")`.
        - The normalized `lock_data` dictionary.
    """

    package_versions = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec
        spec["name"] = normalize_name(spec["name"])

        # Collect all the versions first
        package_versions.setdefault(spec["name"], {})[spec["version"]] = 1

    default_versions = {
        requirement: (lock_id, requirement, list(versions.keys())[0], "__base__")
        for requirement, versions in package_versions.items()
        if len(versions) == 1
    }

    def _fix_version(dep):
        dep["name"] = normalize_name(dep["name"])
        if not "version" in dep:
            # Note that default versions is requirement => (lock_id, name, version, "__base__")
            # So we need to extract the version component here
            dep["version"] = default_versions.get(dep["name"])[2]

    for spec in lock_data.get("package", []):
        # uv omits the artifact URL for local wheels and source archives:
        # their filename/hash records refer to source.path instead.
        source = spec.get("source", {})
        source_url = source.get("url")
        local_path = source.get("path")
        if local_path:
            source_url = _local_file_url(local_path, lockfile_directory)

        if "sdist" in spec and not "url" in spec["sdist"]:
            if source_url == None:
                fail("Source distribution for {} has neither a URL nor a local path".format(spec["name"]))
            spec["sdist"]["url"] = source_url

        for wheel in spec.get("wheels", []):
            if "url" not in wheel and source_url:
                wheel["url"] = source_url

        for dep in spec.get("dependencies", []):
            _fix_version(dep)

        for extra_deps in spec.get("optional-dependencies", {}).values():
            for dep in extra_deps:
                _fix_version(dep)

    return default_versions, package_versions, lock_data

def build_marker_graph(lock_id, lock_data):
    """Builds a dependency graph from a lockfile.

    The graph is represented as a dictionary where the keys are `Dependency`
    tuples `(lock_id, package, version, extra)` and the values are dictionaries
    of their dependencies. The dependency dictionaries are keyed by `Dependency`
    tuples and their values are dictionaries of markers.

    This function also normalizes dependencies on extras. Dependencies without an
    extra are converted to a dependency on the `__base__` extra. Each extra also
    gets a synthetic dependency on the `__base__` package of the same version.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary representing the dependency graph.
    """

    graph = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec
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
                marker = simplify_extra_marker(dep.get("marker", ""), extra_name)
                if marker == None:
                    continue

                extras = dep.get("extra", ["__base__"])
                if "__base__" not in extras:
                    extras = ["__base__"] + extras

                for e in extras:
                    eek = (lock_id, dep["name"], dep["version"], e)
                    graph[ek].setdefault(eek, {})
                    graph[ek][eek][marker] = 1

    return graph

def collect_configurations(lock):
    """Collects all unique platform configurations from the wheels in a lockfile.

    This function identifies all the unique combinations of Python implementation,
    platform, and ABI from the wheel filenames in the lockfile.

    Args:
        lock: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary mapping configuration strings (e.g.,
        "cp39-manylinux_2_17_x86_64-cp39") to a list of `config_setting`
        labels that define the configuration.
    """
    wheel_files = {}

    for package in lock.get("package", []):
        for whl in package.get("wheels", []):
            wheel_files[url_basename(whl["url"])] = 1

    # Configurations depend only on a wheel's trailing tag triple
    # ({python}-{abi}-{platform}.whl); a large lock has thousands of wheel
    # files but only a few dozen distinct triples, so parse and expand one
    # representative wheel per triple.
    tag_triples = {}
    for wheel_name in wheel_files.keys():
        parts = wheel_name.rsplit("-", 3)
        tag_triples["-".join(parts[1:]) if len(parts) == 4 else wheel_name] = wheel_name

    # Platform definitions from groups of configs
    configurations = {}

    for wheel_name in tag_triples.values():
        parsed_wheel = parse_whl_name(wheel_name)
        for python_tag in parsed_wheel.python_tags:
            # Ignore configurations for unsupported interpreters
            if not supported_python(python_tag):
                continue

            for platform_tag in parsed_wheel.platform_tags:
                # Ignore configurations for unsupported platforms
                if not supported_platform(platform_tag):
                    continue

                for abi_tag in parsed_wheel.abi_tags:
                    # Mirror the abi3 expansion `_whl_install_impl` does
                    # via `compatible_python_tags`, so every triple it
                    # references has a matching config_setting here.
                    for cfg_python_tag in compatible_python_tags(python_tag, abi_tag):
                        # Note that we are NOT filtering out
                        # impossible/unsatisfiable python+abi tag
                        # possibilities. It's not aesthetic but it is
                        # simple enough.
                        configuration = "{}-{}-{}".format(cfg_python_tag, platform_tag, abi_tag)

                        configurations[configuration] = [
                            "@aspect_rules_py//uv/private/constraints/platform:{}".format(platform_tag),
                            "@aspect_rules_py//uv/private/constraints/abi:{}".format(abi_tag),
                            "@aspect_rules_py//uv/private/constraints/python:{}".format(cfg_python_tag),
                        ]

    return configurations

def collect_bdists(lock_data):
    """Collects all pre-built wheels (bdists) from a lockfile.

    Args:
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A tuple containing:
        - A dictionary mapping repository names for the wheels to their bdist
          specifications.
        - A dictionary mapping the URL of each wheel to its repository label.
    """
    bdist_specs = {}
    bdist_table = {}
    for package in lock_data.get("package", []):
        for bdist in package.get("wheels", []):
            bdist_repo_name = "whl__{}__{}".format(package["name"], _dist_identifier(bdist))
            bdist_specs[bdist_repo_name] = bdist
            bdist_table[bdist["url"]] = "@{}//:whl".format(bdist_repo_name)

    return bdist_specs, bdist_table

def collect_sdists(
        lock_id,
        lock_data):
    """Collects all source distributions (sdists) from a lockfile.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A tuple containing:
        - A dictionary mapping repository names for the sdists to their
          specifications.
        - A dictionary mapping sdist build keys to their repository labels.
    """
    sdist_specs = {}
    sdist_table = {}
    for package in lock_data.get("package", []):
        k = "sdist_build__{}__{}__{}".format(lock_id, package["name"], normalize_version(package["version"]))
        if "sdist" in package:
            sdist = package["sdist"]

            sdist_repo_name = "sdist__{}__{}".format(package["name"], _dist_identifier(sdist))
            sdist_specs[sdist_repo_name] = {"file": sdist}
            sdist_table[k] = "@{}//file".format(sdist_repo_name)

        elif "git" in package["source"]:
            git_url = package["source"]["git"]
            git_cfg = parse_git_url(git_url)
            sdist_repo_name = "sdist_git__{}__{}".format(package["name"], sha1(git_url)[:16])

            sdist_table[k] = "@{}//file".format(sdist_repo_name)
            sdist_cfg = try_git_to_http_archive(git_cfg)
            if sdist_cfg:
                sdist_specs[sdist_repo_name] = {"file": sdist_cfg}

            else:
                sdist_specs[sdist_repo_name] = {"git": git_cfg}

    return sdist_specs, sdist_table
