# pip = use_repo("@aspect_rules_py//pip:extesion.bzl", "pip")
#
# pip.declare_hub(hub_name = "my_pip")
#
# pip.declare_venv(hub_name = "my_pip", venv_name = "a")
# pip.declare_venv(hub_name = "my_pip", venv_name = "b")
# pip.declare_venv(hub_name = "my_pip", venv_name = "c")
#
# pip.lockfile(hub_name = "my_pip", venv_name = "a", lockfile = "third_party/py/venvs/pylock-a.toml")
# pip.lockfile(hub_name = "my_pip", venv_name = "b", lockfile = "third_party/py/venvs/pylock-b.toml")
# pip.lockfile(hub_name = "my_pip", venv_name = "c", lockfile = "third_party/py/venvs/pylock-c.toml")
#
# use_repo(pip, "my_pip")
#
# Note that platform constraints are specified by markers in the lockfile, they cannot be explicitly specified.
# Note that dependency cycles are now inferred and groups calculated automatically, they cannot be specified.

# FIXME: Need to add package name sanitization/mangling
# https://github.com/bazel-contrib/rules_python/blob/main/python/private/normalize_name.bzl

# FIXME: Need to explicitly test a lockfile with platform-conditional deps (tensorflow cpu vs gpu mac/linux)

# FIXME: Need to explicitly test a lockfile with a cycle (airflow & friends)

# FIXME: Need to add machinery for parsing wheel files and deciding compatability

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//pip/private/pip_hub:repository.bzl", "pip_hub")
load("//pip/private/sdist_build:repository.bzl", "sdist_build")
load("//pip/private/whl_install:repository.bzl", "whl_install")
load("//pip/private/whl_install:parse_whl_name.bzl", "parse_whl_name")
load("//pip/private/venv_hub:repository.bzl", "venv_hub")
load(":sccs.bzl", "sccs")
load(":sha1.bzl", "sha1")

def _parse_hubs(module_ctx):
    # As with `rules_python` hub names have to be globally unique :/
    hub_specs = {}

    # Collect all hubs, ensure we have no dupes
    for mod in module_ctx.modules:
        for hub in mod.tags.declare_hub:
            hub_specs.setdefault(hub.hub_name, {})
            hub_specs[hub.hub_name][mod.name] = 1

    problems = []
    for hub_name, modules in hub_specs.items():
        if len(modules.keys()) > 1:
            problems.append(
                "Hub name {} should have been globally unique but was used by the following modules:{}".format(
                    hub_name,
                    "".join(["\n - {}".format(it) for it in modules.keys()])
                )
            )

    if problems:
        fail(problems)

    return hub_specs


def _parse_venvs(module_ctx, hub_specs):
    # Venvs should only be declared once and must refer to a hub in the same module
    # Maps hubs to virtualenvs
    venv_specs = {}

    problems = []

    # Collect all hubs, ensure we have no dupes
    for mod in module_ctx.modules:
        for venv in mod.tags.declare_venv:
            if venv.hub_name not in hub_specs or mod.name not in hub_specs[venv.hub_name]:
                problems.append("Venv {} in {} refers to hub {} which is not configured for that module".format(venv.venv_name, venv.hub_name, mod.name))

            venv_specs.setdefault(venv.hub_name, {})
            venv_specs[venv.hub_name][venv.venv_name] = 1

    if problems:
        fail("\n".join(problems))

    return venv_specs


def _parse_locks(module_ctx, yq, venv_specs):
    # Map of hub to venv to lock contents
    lock_specs = {}

    problems = []

    for mod in module_ctx.modules:
        for lock in mod.tags.lockfile:
            if lock.hub_name not in venv_specs or lock.venv_name not in venv_specs[lock.hub_name]:
                problems.append("Lock {} in {} refers to hub {} which is not configured for that module".format(lock.lockfile, mod.name, lock.hub_name))

            lock_specs.setdefault(lock.hub_name, {})

            result = module_ctx.execute([yq, lock.lockfile])
            if result.return_code != 0:
                problems.append("Failed to extract {} in {};\n{}".format(lock.lockfile, mod.name, result.stderr))
                continue

            # FIXME: Should validate the lockfile but for now just stash it
            lock_specs[lock.hub_name][lock.venv_name] = json.decode(result.stdout)

    if problems:
        fail("\n".join(problems))

    return lock_specs


def _collect_configurations(repository_ctx, lock_specs):
    # Set of wheel names which we're gonna do a second pass over to collect configuration names

    # The config repo scheme is as follows:
    # //_parts/version/major:2-99
    # //_parts/version/minor:2-99
    # //_parts/version/patch:2-99 | any
    # //_parts/os:{any,linux,manylinux,musllinux,macos,}

    wheel_files = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                if "registry" not in package["source"]:
                    continue

                for whl in package.get("wheels", []):
                    url = whl["url"]
                    wheel_name = url.split("/")[-1] # Find the trailing file name
                    wheel_files[wheel_name] = 1

    abi_tags = {}
    platform_tags = {}
    python_tags = {}

    # Platform definitions from groups of configs
    configurations = {}

    for wheel_name in wheel_files.keys():
        parsed_wheel = parse_whl_name(wheel_name)
        for python_tag in parsed_wheel.python_tags:
            python_tags[python_tag] = 1

            for platform_tag in parsed_wheel.platform_tags:
                platform_tags[platform_tag] = 1

                for abi_tag in parsed_wheel.abi_tags:
                    abi_tags[abi_tag] = 1

                    configuration = "{}-{}-{}".format(python_tag, platform_tag, abi_tag)

                    configurations[configuration] = [
                        "@aspect_rules_py//pip/private/config/python:{}".format(python_tag),
                        "@aspect_rules_py//pip/private/config/platform:{}".format(platform_tag),
                        "@aspect_rules_py//pip/private/config/abi:{}".format(abi_tag),
                    ]

    print(abi_tags)
    print(platform_tags)
    print(python_tags)
    print(configurations)


def _sdist_repo_name(package):
    """We key sdist repos strictly by their name and content hash."""

    return  "sdist__{}__{}".format(
        package["name"],
        package["sdist"]["hash"][len("shasum:"):][:8],
    )


def _raw_sdist_repos(module_ctx, lock_specs):
    # Map of hub -> venv -> requirement -> version -> repo name
    repo_defs = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                if "registry" not in package["source"]:
                    continue

                sdist = package["sdist"]
                url = sdist["url"]
                shasum = sdist["hash"][len("sha256:"):]

                # FIXME: Do we need to factor in the shasum or source her? Could
                # have two or more sources for one "artifact".
                #
                # Assume (potentially a problem!)
                name = _sdist_repo_name(package)
                downloaded_file_path = url.split("/")[-1]
                spec = dict(
                    name = name,
                    downloaded_file_path = downloaded_file_path,
                    urls = [url],
                    sha256 = shasum,
                )
                if name not in repo_defs:
                    repo_defs[name] = spec
                elif name in repo_defs and url not in repo_defs[name]["urls"]:
                    repo_defs[name]["urls"].append(url)

    # FIXME: May need to thread netrc or other credentials through to here?
    for spec in repo_defs.values():
        http_file(**spec)


def _whl_repo_name(package, whl):
    """We key whl repos strictly by their name and content hash."""

    return  "whl__{}__{}".format(
        package["name"],
        whl["hash"][len("shasum:"):][:8],
    )


def _raw_whl_repos(module_ctx, lock_specs):
    repo_defs = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                if "registry" not in package["source"]:
                    continue

                wheels = package.get("wheels", [])
                for whl in wheels:

                    url = whl["url"]
                    shasum = whl["hash"][len("sha256:"):]

                    # FIXME: Do we need to factor in the shasum or source her? Could
                    # have two or more sources for one "artifact".
                    #
                    # Assume (potentially a problem!)
                    name = _whl_repo_name(package, whl)
                    downloaded_file_path = url.split("/")[-1]
                    spec = dict(
                        name = name,
                        downloaded_file_path = downloaded_file_path,
                        urls = [url],
                        sha256 = shasum,
                    )
                    repo_defs[name] = spec

    # FIXME: May need to thread netrc or other credentials through to here?
    for spec in repo_defs.values():
        http_file(**spec)


def _sbuild_repo_name(hub, venv, package):
    return "sbuild__{}__{}__{}".format(
        hub, venv, package["name"],
    )

def _venv_target(hub_name, venv, package_name):
    return "{}//{}".format(
        _venv_hub_name(hub_name, venv),
        package_name,
    )

def _sbuild_repos(module_ctx, lock_specs):
    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                if "registry" not in package["source"]:
                    continue

                sdist_build(
                    name = _sbuild_repo_name(hub_name, venv_name, package),
                    src = "@" + _sdist_repo_name(package) + "//file",
                    deps = [
                        "@" + _venv_target(hub_name, venv_name, package["name"])
                        for package in package.get("dependencies", [])
                    ],
                )

def _whl_install_repo_name(hub, venv, package):
    return "whl_install__{}__{}__{}".format(
        hub, venv, package["name"],
    )

def _whl_install_repos(module_ctx, lock_specs):
    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                if "registry" not in package["source"]:
                    continue

                # This is where we need to actually choose which wheel we will
                # "install", and so this is where prebuild selection needs to
                # happen according to constraints.

                prebuilds = {}
                for whl in package.get("wheels", []):
                    # FIXME: Convert filenames to coordinates here?
                    prebuilds[whl["url"].split("/")[-1]] = _whl_repo_name(package, whl) + "//file"

                # FIXME: This should accept a common constraint for when to choose source builds
                # Needs to create a `py_library` or superset rule wrapping the resulting files
                whl_install(
                    name = _whl_install_repo_name(hub_name, venv_name, package),
                    prebuilds = json.encode(prebuilds),
                    sbuild = _sbuild_repo_name(hub_name, venv_name, package),
                )

def _venv_hub_name(hub, venv):
    return "venv__{}__{}".format(
        hub, venv,
    )

def _group_repos(module_ctx, lock_specs):
    # Hub -> requirement -> venv -> True
    # For building hubs we need to know what venv configurations a given
    package_venvs = {}

    for hub_name, venvs in lock_specs.items():
        package_venvs[hub_name] = {}

        for venv_name, lock in venvs.items():

            # First we need to build the adjacency graph
            graph = {}

            for package in lock.get("package", []):
                if "registry" not in package["source"]:
                    continue

                deps = []

                # Enter the package into the venv internal graph
                graph[package["name"]] = deps
                for d in package.get("dependencies", []):
                    deps.append(d["name"])

                # Enter the package into the venv hub manifest
                package_venvs[hub_name].setdefault(package["name"], {})
                package_venvs[hub_name][package["name"]][venv_name] = 1

            # So we can find sccs/clusters which need to co-occur
            cycle_groups = sccs(graph)

            # Now we can assign names to the sccs and collect deps Note that
            # _every_ node in the graph will be in _a_ scc, those sccs are just
            # size 1 if the node isn't part of a cycle.
            #
            # Rather than trying to handle size-1 clusters separately which adds
            # implementation complexity we handle all clusters the same.
            named_sccs = {}
            scc_aliases = {}
            deps = {}
            for scc in cycle_groups:
                # Make up a deterministic name for the scc.
                # What it is doesn't matter.
                # Could be gensym-style numeric too.
                name = sha1(json.encode(scc))[:8]
                deps[name] = {}
                named_sccs[name] = scc

                for node in scc:
                    # Mark scc component with an alias
                    scc_aliases[node] = name

                    # Mark the scc as depending on this package because it does
                    deps[name][node] = 1

                    # Collect deps of the component which are not in the scc We
                    # use dict-to-one as a set because there could be multiple
                    # members of an scc which take a dependency on the same
                    # thing outside the scc.
                    for d in graph[node]:
                        if d not in scc:
                            deps[name][d] = 1

            # At this point we have mapped every package to an scc (possibly of
            # size 1) which it participates in, named those sccs, and identified
            # their direct dependencies beyond the scc. So we can just lay down
            # targets.

            venv_hub(
                name = _venv_hub_name(hub_name, venv_name),
                aliases = scc_aliases,  # String dict
                sccs = named_sccs,      # List[String] dict
                deps = deps,            # List[String] dict
                installs = {
                    package: _whl_install_repo_name(hub_name, venv_name, {"name": package})
                    for package in sorted(graph.keys())
                },
            )

    return package_venvs


def _hub_repos(module_ctx, lock_specs, package_venvs):
    for hub_name, packages in package_venvs.items():
        pip_hub(
            name = hub_name,
            hub_name = hub_name,
            venvs = lock_specs[hub_name].keys(),
            packages = {
                package: venvs.keys()
                for package, venvs in packages.items()
            }
        )

def _pip_impl(module_ctx):
    # toml2json_tool = _provision_yq(module_ctx)
    toml2json_tool = module_ctx.path("/Users/arrdem/.cargo/bin/toml2json")

    hub_specs = _parse_hubs(module_ctx)

    venv_specs = _parse_venvs(module_ctx, hub_specs)

    lock_specs = _parse_locks(module_ctx, toml2json_tool, venv_specs)

    # Roll through all the configured wheels, collect & validate the unique
    # platform configurations so that we can go create an appropriate power set
    # of conditions.
    configurations = _collect_configurations(module_ctx, lock_specs)

    # Roll through and create sdist and whl repos for all configured sources
    # Note that these have no deps to this point
    _raw_sdist_repos(module_ctx, lock_specs)
    _raw_whl_repos(module_ctx, lock_specs)

    # Roll through and create per-venv sdist build repos
    _sbuild_repos(module_ctx, lock_specs)

    # Roll through and create per-venv whl installs
    _whl_install_repos(module_ctx, lock_specs)

    # Roll through and create per-venv group/dep layers
    package_venvs = _group_repos(module_ctx, lock_specs)

    # Finally the hubs themselves are fully trivialized
    _hub_repos(module_ctx, lock_specs, package_venvs)


_hub_tag = tag_class(
    attrs = {
        "hub_name": attr.string(),
    },
)

_venv_tag = tag_class(
    attrs = {
        "hub_name": attr.string(),
        "venv_name": attr.string(),
    }
)

_lockfile_tag = tag_class(
    attrs = {
        "hub_name": attr.string(),
        "venv_name": attr.string(),
        "lockfile": attr.label(),
    }
)

pip = module_extension(
    implementation = _pip_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "declare_venv": _venv_tag,
        "lockfile": _lockfile_tag,
    }
)
