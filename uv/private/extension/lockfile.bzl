"""
Machinery specific to interacting with a uv.lock
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load(":git_utils.bzl", "parse_git_url", "try_git_to_http_archive")

def normalize_deps(lock_id, lock_data):
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
        # Backfill the sdist URL if the source is a URL file
        if "sdist" in spec and not "url" in spec["sdist"]:
            spec["sdist"]["url"] = spec["source"]["url"]

        for dep in spec.get("dependencies", []):
            _fix_version(dep)

        for extra_deps in spec.get("optional-dependencies", {}).values():
            for dep in extra_deps:
                _fix_version(dep)

    return default_versions, lock_data

MAGIC_ACTIVATE_BASE_MARKER = "magic_activate_base == 1"

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
                extras = dep.get("extra", ["__base__"])
                if "__base__" not in extras:
                    extras = ["__base__"] + extras

                for e in extras:
                    eek = (lock_id, dep["name"], dep["version"], e)
                    graph[ek].setdefault(eek, {})
                    graph[ek][eek][dep.get("marker", "")] = 1

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
            url = whl["url"]
            wheel_name = url.split("/")[-1]  # Find the trailing file name
            wheel_files[wheel_name] = 1

    abi_tags = {}
    platform_tags = {}
    python_tags = {}

    # Platform definitions from groups of configs
    configurations = {}

    for wheel_name in wheel_files.keys():
        parsed_wheel = parse_whl_name(wheel_name)
        for python_tag in parsed_wheel.python_tags:
            # Ignore configurations for unsupported interpreters
            if not supported_python(python_tag):
                continue

            python_tags[python_tag] = 1

            for platform_tag in parsed_wheel.platform_tags:
                # Ignore configurations for unsupported platforms
                if not supported_platform(platform_tag):
                    continue

                platform_tags[platform_tag] = 1

                for abi_tag in parsed_wheel.abi_tags:
                    abi_tags[abi_tag] = 1

                    # Note that we are NOT filtering out
                    # impossible/unsatisfiable python+abi tag possibilities.
                    # It's not aesthetic but it is simple enough.
                    configuration = "{}-{}-{}".format(python_tag, platform_tag, abi_tag)

                    configurations[configuration] = [
                        "@aspect_rules_py//uv/private/constraints/platform:{}".format(platform_tag),
                        "@aspect_rules_py//uv/private/constraints/abi:{}".format(abi_tag),
                        "@aspect_rules_py//uv/private/constraints/python:{}".format(python_tag),
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
        - A dictionary mapping the hash of each wheel to its repository label.
    """
    bdist_specs = {}
    bdist_table = {}
    for package in lock_data.get("package", []):
        for bdist in package.get("wheels", []):

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
        allow_git_to_http_conversion = False):
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

            # FIXME: Replace with a policy mechanism
            if allow_git_to_http_conversion:
                sdist_cfg = try_git_to_http_archive(git_cfg)
                sdist_repo_name = "sdist_git__{}__{}".format(package["name"], sha1(git_url)[:16])
                sdist_table[k] = "@{}//file".format(sdist_repo_name)

                if sdist_cfg:
                    sdist_specs[sdist_repo_name] = {"file": sdist_cfg}
                    continue

            sdist_specs[sdist_repo_name] = {"git": git_cfg}

    return sdist_specs, sdist_table

def collect_markers(graph):
    """Collects all unique marker expressions from the dependency graph.

    Args:
        graph: The dependency graph.

    Returns:
        A dictionary mapping each unique marker expression to its SHA-1 hash.
    """
    acc = {}
    for _dep, nexts in graph.items():
        for _next, markers in nexts.items():
            for marker in markers.keys():
                # sha1 is "expensive" so we minimize it
                if marker and marker not in acc:
                    acc[marker] = sha1(marker)

    return acc
