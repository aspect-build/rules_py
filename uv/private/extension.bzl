"""
An implementation of fetching dependencies based on consuming UV's lockfiles.

Follows in the footsteps of rules_js's pnpm support by consuming a lockfile
which contains enough information to produce a virtualenv without performing any
dynamic resolution.

Relies on the lockfile to enumerate:
- Source distributions & their digests
- Prebuilt distribitons & their digests
- The dependencies of digests

## Example

    uv = use_repo("@aspect_rules_py//uv:extension.bzl", "uv")
    uv.declare_hub(hub_name = "uv")
    
    uv.declare_venv(hub_name = "uv", venv_name = "a")
    uv.lockfile(hub_name = "uv", venv_name = "a", lockfile = "third_party/py/venvs/uv-a.lock")

    uv.declare_venv(hub_name = "uv", venv_name = "b")
    uv.lockfile(hub_name = "uv", venv_name = "b", lockfile = "third_party/py/venvs/uv-b.lock")

    use_repo(uv, "uv")

## Features

- Supports cross-platform builds of wheels
- Supports hermetic source builds of wheels
- Automatically handles dependency cycles

## Appendix

[1] https://peps.python.org/pep-0751/
[2] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
"""

# Note that platform constraints are specified by markers in the lockfile, they cannot be explicitly specified.

# FIXME: Need to add package name sanitization/mangling
# https://github.com/bazel-contrib/rules_python/blob/main/python/private/normalize_name.bzl

# FIXME: Need to explicitly test a lockfile with platform-conditional deps (tensorflow cpu vs gpu mac/linux)

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//uv/private/constraints:repository.bzl", "configurations_hub")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load("//uv/private/hub:repository.bzl", "hub_repo")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/tomltool:toml.bzl", "toml")
load("//uv/private/venv_hub:repository.bzl", "venv_hub")
load("//uv/private/whl_install:repository.bzl", "whl_install")
load(":normalize_name.bzl", "normalize_name")
load(":parse_whl_name.bzl", "parse_whl_name")
load(":sccs.bzl", "sccs")
load(":sha1.bzl", "sha1")

def _ignored_package(package):
    """
    Indicate whether the package manifest is something we're ignoring.
    This is a workaround for the lockfile package which represents the project itself.
    """

    # Remote package sources
    # - { source = { registry = "https://some.registry/..." } }
    # - { source = { url = "https://ton.hosting.biz/some.whl" } }
    # FIXME: Git URLs?
    # FIXME: Egg URLs?
    #
    # These seem to be used by the package itself
    # - { source = { editable = "." } }
    # - { source = { virtual = "." } }
    if "virtual" in package["source"] and package["source"]["virtual"] == ".":
        return True

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
                    "".join(["\n - {}".format(it) for it in modules.keys()]),
                ),
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

def _parse_locks(module_ctx, venv_specs):
    # Map of hub to venv to lock contents
    lock_specs = {}

    problems = []

    # FIXME: Add support for setting a default venv on a venv hub
    for mod in module_ctx.modules:
        for lock in mod.tags.lockfile:
            if lock.hub_name not in venv_specs or lock.venv_name not in venv_specs[lock.hub_name]:
                problems.append("Lock {} in {} refers to hub {} which is not configured for that module".format(lock.lockfile, mod.name, lock.hub_name))

            lock_specs.setdefault(lock.hub_name, {})

            lockfile = toml.decode_file(module_ctx, lock.lockfile)
            if not lockfile:
                problems.append("Failed to extract {} in {}".format(lock.lockfile, mod.name))
                continue

            # Apply name mangling from PyPi package names to Bazel friendly
            # package names here, once.
            packages = lockfile.get("package", [])
            for package in list(packages):
                # Just remove ignored packages now rather than filtering them
                # out over and over again.
                if _ignored_package(package):
                    packages.remove(package)
                    continue

                package["name"] = normalize_name(package["name"])
                if "dependencies" in package:
                    for d in package["dependencies"]:
                        d["name"] = normalize_name(d["name"])

                # Note that we also have to mangle the optional deps so they tie
                # off too. We don't mangle group names because they're
                # eliminated when we resolve the depgraph.
                if "optional-dependencies" in package:
                    for name, group in package["optional-dependencies"].items():
                        for d in group:
                            d["name"] = normalize_name(d["name"])

            # FIXME: Should validate the lockfile but for now just stash it
            # Validating in starlark kinda rots anyway
            lock_specs[lock.hub_name][lock.venv_name] = lockfile

    if problems:
        fail("\n".join(problems))

    return lock_specs

def _collect_configurations(repository_ctx, lock_specs):
    # Set of wheel names which we're gonna do a second pass over to collect configuration names

    wheel_files = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
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

def _sdist_repo_name(package):
    """We key sdist repos strictly by their name and content hash."""

    return "sdist__{}__{}".format(
        package["name"],
        package["sdist"]["hash"][len("shasum:"):][:8],
    )

def _raw_sdist_repos(module_ctx, lock_specs):
    # Map of hub -> venv -> requirement -> version -> repo name
    repo_defs = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                sdist = package.get("sdist")
                if sdist == None:
                    continue

                # Note that for source=url=... packages, the URL may not be
                # repeated in the sdist spec so we have to replicate it down.
                url = sdist.get("url", package["source"].get("url"))
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

    return "whl__{}__{}".format(
        package["name"],
        whl["hash"][len("shasum:"):][:8],
    )

def _raw_whl_repos(module_ctx, lock_specs):
    repo_defs = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                wheels = package.get("wheels", [])
                for whl in wheels:
                    url = whl["url"]
                    shasum = whl["hash"][len("sha256:"):]

                    # FIXME: Do we need to factor in the shasum or source her? Could
                    # have two or more sources for one "artifact".
                    #
                    # Assume (potentially a problem!)
                    name = _whl_repo_name(package, whl)
                    print("Creating whl repo", name)
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
        hub,
        venv,
        package["name"],
    )

def _venv_target(hub_name, venv, package_name):
    return "{}//:{}".format(
        _venv_hub_name(hub_name, venv),
        package_name,
    )

def _sbuild_repos(module_ctx, lock_specs):
    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                if "sdist" not in package:
                    continue

                name = _sbuild_repo_name(hub_name, venv_name, package)
                print("Creating sdist repo", name)
                sdist_build(
                    name = name,
                    src = "@" + _sdist_repo_name(package) + "//file",
                    deps = [
                        "@" + _venv_target(hub_name, venv_name, package["name"])
                        for package in package.get("dependencies", [])
                    ],
                )

def _whl_install_repo_name(hub, venv, package):
    return "whl_install__{}__{}__{}".format(
        hub,
        venv,
        package["name"],
    )

def _whl_install_repos(module_ctx, lock_specs):
    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                # This is where we need to actually choose which wheel we will
                # "install", and so this is where prebuild selection needs to
                # happen according to constraints.
                prebuilds = {}
                for whl in package.get("wheels", []):
                    prebuilds[whl["url"].split("/")[-1]] = _whl_repo_name(package, whl) + "//file"

                # FIXME: This should accept a common constraint for when to
                # choose source builds over prebuilds.

                # FIXME: Needs to explicitly mark itself as being compatible
                # only with the single venv. Shouldn't be possible to force this
                # target to build when the venv hub is not pointed to this venv.
                name = _whl_install_repo_name(hub_name, venv_name, package)
                print("Creating install repo", name)
                whl_install(
                    name = name,
                    prebuilds = json.encode(prebuilds),
                    sbuild = "@" + _sbuild_repo_name(hub_name, venv_name, package) + "//:whl" if "sdist" in package else None,
                )

def _venv_hub_name(hub, venv):
    return "venv__{}__{}".format(
        hub,
        venv,
    )

def _group_repos(module_ctx, lock_specs):
    # Hub -> requirement -> venv -> True
    # For building hubs we need to know what venv configurations a given

    # TODO: Missing support for `marker=""` specifications in `dependencies`.
    # Deps may be conditional on this or that predicate being satisfied.
    # Dependencies which have markers need to be rewritten so that the
    # dependency edge goes through a select.
    #
    # TODO: What happens if you have a cycle only when this or that feature is
    # active? Probably the fix is to turn on all dependency edges

    package_venvs = {}

    for hub_name, venvs in lock_specs.items():
        package_venvs[hub_name] = {}

        for venv_name, lock in venvs.items():
            # Index all the packages by name so activating extras is easy
            packages = {
                package["name"]: package
                for package in lock.get("package", [])
            }

            # Build a graph {name: {dependency_name: dependency_marker_condition}}
            graph = {}

            for name, package in packages.items():
                deps = {}

                # Enter the package into the venv internal graph
                graph.setdefault(package["name"], {})

                for d in package.get("dependencies", []):
                    # Or in all the dep bits
                    graph[package["name"]][d["name"]] = d.get("marker", "")

                    # Activate extras
                    extras = packages[d["name"]].get("optional-dependencies", {})
                    for extra in d.get("extra", []):
                        for extra_dep in extras.get(extra, []):
                            graph.setdefault(d["name"], {})
                            graph[d["name"]][extra_dep["name"]] = extra_dep.get("marker", "")

                # Enter the package into the venv hub manifest
                package_venvs[hub_name].setdefault(package["name"], {})
                package_venvs[hub_name][package["name"]][venv_name] = 1

            # So we can find sccs/clusters which need to co-occur
            # Note that we're assuming ALL marker conditional deps are live.
            cycle_groups = sccs({k: v.keys() for k, v in graph.items()})

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

            # TODO: How do we plumb markers through here?

            # At this point we have mapped every package to an scc (possibly of
            # size 1) which it participates in, named those sccs, and identified
            # their direct dependencies beyond the scc. So we can just lay down
            # targets.
            name = _venv_hub_name(hub_name, venv_name)
            print("Creating venv hub", name)
            venv_hub(
                name = name,
                aliases = scc_aliases,  # String dict
                sccs = named_sccs,  # List[String] dict
                deps = deps,  # List[String] dict
                installs = {
                    package: _whl_install_repo_name(hub_name, venv_name, {"name": package})
                    for package in sorted(graph.keys())
                },
            )

    return package_venvs

def _hub_repos(module_ctx, lock_specs, package_venvs):
    for hub_name, packages in package_venvs.items():
        print("Creating uv hub", hub_name)
        hub_repo(
            name = hub_name,
            hub_name = hub_name,
            venvs = lock_specs[hub_name].keys(),
            packages = {
                package: venvs.keys()
                for package, venvs in packages.items()
            },
        )

def _uv_impl(module_ctx):
    hub_specs = _parse_hubs(module_ctx)

    venv_specs = _parse_venvs(module_ctx, hub_specs)

    lock_specs = _parse_locks(module_ctx, venv_specs)

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

    configurations_hub(
        name = "aspect_rules_py_pip_configurations",
        configurations = configurations,
    )

_hub_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "default_venv_name": attr.string(),
    },
)

_venv_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "venv_name": attr.string(mandatory = True),
    },
)

_lockfile_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "venv_name": attr.string(mandatory = True),
        "lockfile": attr.label(mandatory = True),
    },
)

uv = module_extension(
    implementation = _uv_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "declare_venv": _venv_tag,
        "lockfile": _lockfile_tag,
    },
)
