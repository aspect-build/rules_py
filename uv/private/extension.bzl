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

# FIXME: Need to explicitly test a lockfile with platform-conditional deps (tensorflow cpu vs gpu mac/linux)

load("@bazel_features//:features.bzl", features = "bazel_features")
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

    Args:
        package (dict): A package record from a lockfile

    Returns:
        bool indicating whether the package should be skipped
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

    return False

def _parse_hubs(module_ctx):
    """
    Parse hub declaration tags.

    Produces a hubs table we use to validate venv registrations.

    Args:
        module_ctx (module_ctx): The Bazel module context

    Returns:
        dict; parsed hub specs.
    """

    # As with `rules_python` hub names have to be globally unique :/
    hub_specs = {}

    # Collect all hubs, ensure we have no dupes
    for mod in module_ctx.modules:
        for hub in mod.tags.declare_hub:
            hub_specs.setdefault(hub.hub_name, {})
            hub_specs[hub.hub_name][mod.name] = 1

    # Note that we ARE NOT validating that the same hub name is registered by
    # one and only one repository. This allows `@pypi` which we think should be
    # the one and only conventional hub to be referenced by many modules since
    # we disambiguate the build configuration on the "venv" not the hub.

    return hub_specs

def _parse_venvs(module_ctx, hub_specs):
    """
    Parse venv declaration tags.

    Validates against the parsed hub specs to produce appropriate errors.

    Produces a hub to venv table we use for validating lockfiles and overrides.

    Args:
        module_ctx (module_ctx): The Bazel module context
        hub_specs (dict): The previously parsed hub specs

    Returns:
        dict; parsed venv specs.
    """

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
    """
    Parse lockfile tags.

    Validates against parsed hubs and venvs to produce appropriate errors.

    Applies a bunch of package normalization here at the entrypoint before we forget.

    Produces a hub to venv to package to package descriptor mapping.

    Args:
        module_ctx (module_ctx): The Bazel module context
        venv_specs (dict): The previously parsed venv specs

    Returns:
        dict; collected lockfiles.
    """

    lock_specs = {}

    # FIXME: Add support for setting a default venv on a venv hub
    for mod in module_ctx.modules:
        for lock in mod.tags.lockfile:
            req_whls = {}

            if lock.hub_name not in venv_specs or lock.venv_name not in venv_specs[lock.hub_name]:
                fail("Lock {} in {} refers to hub {} which is not configured for that module".format(lock.src, mod.name, lock.hub_name))

            lock_specs.setdefault(lock.hub_name, {})
            if lock.venv_name in lock_specs[lock.hub_name]:
                fail("Multiple lockfiles detected for hub %s venv %s!" % (lock.hub_name, lock.venv_name))

            lockfile = toml.decode_file(module_ctx, lock.src)
            if lockfile.get("version") != 1:
                fail("Lockfile %s is an unsupported format version!" % lock.src)

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

                # Mark that prebuilds are available for this package
                req_whls[package["name"]] = package.get("wheels")

                if package["name"] == "private":
                    fail("Unable to parse lockfile %s due to reserved 'private' package which collides with implementation details" % lock.src)

                if "dependencies" in package:
                    for d in package["dependencies"]:
                        d["name"] = normalize_name(d["name"])

                # Note that we also have to mangle the optional deps so they tie
                # off too. We don't mangle group names because they're
                # eliminated when we resolve the depgraph.
                if "optional-dependencies" in package:
                    for _name, group in package["optional-dependencies"].items():
                        for d in group:
                            d["name"] = normalize_name(d["name"])

            problems = []
            has_tools = "build" in req_whls and "setuptools" in req_whls
            for req, whls in req_whls.items():
                if not whls and not has_tools:
                    problems.append(req)

            if problems:
                fail("""Error in lockfile {lockfile}

The requirements `build` and `setuptools` are missing from, but the following requirements only provide sdists.
Please update your lockfile to provide build tools in order to enable sdist support.

Problems:
{problems}""".format(
                    lockfile = lock.src,
                    problems = "\n".join(
                        [" - " + it for it in problems],
                    ),
                ))

            # FIXME: Should validate the lockfile but for now just stash it
            # Validating in starlark kinda rots anyway
            lock_specs[lock.hub_name][lock.venv_name] = lockfile

    return lock_specs

_default_annotations = struct(
    per_package = {},
    default_build_deps = [
        {"name": "setuptools"},
        {"name": "build"},
    ],
)

def _parse_annotations(module_ctx, hub_specs, venv_specs):
    """
    Parse and validate requirement annotations.

    Requirement annotations allow us to attach stuff (build deps) to requirement
    targets which the uv lockfile doesn't (currently) have a way to express.

    Returns a table from hub to venv to an annotations struct for that venv.

    Venv annotations structs are

    Dep = TypedDict({"name": str})
    record(
       per_package=Dict[str, List[Dep]],
       default_build_deps=List[Dep],
    )

    Args:
        module_ctx (module_ctx): The Bazel module context
        hub_specs (dict): The previously parsed hub specs
        venv_specs (dict): The previously parsed venv specs

    Returns:
        dict; collected requirement annotations.
    """

    annotation_specs = {}

    for mod in module_ctx.modules:
        for ann in mod.tags.unstable_annotate_requirements:
            if ann.hub_name not in hub_specs:
                fail("Annotations file %s attaches to undefined hub %s" % (ann.src, ann.hub_name))

            annotation_specs.setdefault(ann.hub_name, {})

            if ann.venv_name not in venv_specs.get(ann.hub_name, {}):
                fail("Annotations file %s attaches to undefined venv %s" % (ann.src, ann.venv_name))

            # FIXME: Allow the default build deps to be changed
            annotation_specs[ann.hub_name].setdefault(ann.venv_name, struct(
                per_package = {},
                default_build_deps = [] + _default_annotations.default_build_deps,
            ))

            ann_content = toml.decode_file(module_ctx, ann.src)
            if ann_content.get("version") != "0.0.0":
                fail("Annotations file %s doesn't specify a valid version= key" % ann.src)

            for package in ann_content.get("package", []):
                if not "name" in package:
                    fail("Annotations file %s is invalid; all [[package]] entries must have a name" % ann.src)

                # Apply name normalization so we don't forget about it
                package["name"] = normalize_name(package["name"])

                if package["name"] in annotation_specs[ann.hub_name][ann.venv_name].per_package:
                    fail("Annotation conflict! Package %s is annotated in venv %s multiple times!" % (package["name"], ann.venv_name))

                if "build-dependencies" in package:
                    for it in package["build-dependencies"]:
                        it["name"] = normalize_name(it["name"])

                annotation_specs[ann.hub_name][ann.venv_name].per_package[package["name"]] = package

    return annotation_specs

def _parse_overrides(module_ctx, lock_specs):
    """
    Parse and validate override tags.

    Override tags allow users to replace a requirement's `install` target in a
    venv with a different (presumably firstparty) Bazel target.

    Overridden targets will have their sdist and whl repos pruned from the build
    graph, and don't have a conventional install target.

    Args:
        module_ctx (module_ctx): The Bazel module context
        lock_specs (dict): The previously parsed venv specs

    Returns:
        dict; map of hub to venv to package to override label

    """

    overrides = {}

    for mod in module_ctx.modules:
        for override in mod.tags.override_requirement:
            if override.hub_name not in lock_specs:
                fail("Override %r references undeclared hub" % (override,))

            # Insert a base mapping for the hub
            overrides.setdefault(override.hub_name, {})

            if override.venv_name not in lock_specs[override.hub_name]:
                fail("Override %r references venv not in the hub" % (override,))

            # Insert a base mapping for the venv
            overrides[override.hub_name].setdefault(override.venv_name, {})

            req = normalize_name(override.requirement)
            if not any([it["name"] == req for it in lock_specs[override.hub_name][override.venv_name].get("package", [])]):
                fail("Override  for %r references a requirement not in venv %r of hub %r" % (req, override.venv_name, override.hub_name))

            if req in overrides[override.hub_name][override.venv_name]:
                fail("Override collision! Requirement %r of venv %r of hub %r has multiple overrides" % (req, override.venv_name, override.hub_name))

            overrides[override.hub_name][override.venv_name][req] = override.target

    return overrides

def _collect_configurations(_module_ctx, lock_specs):
    # Set of wheel names which we're gonna do a second pass over to collect configuration names

    wheel_files = {}

    for _hub_name, venvs in lock_specs.items():
        for _venv_name, lock in venvs.items():
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

def _raw_sdist_repos(_module_ctx, lock_specs, override_specs):
    # Map of hub -> venv -> requirement -> version -> repo name
    repo_defs = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                # This is an overridden package, don't declare repos for it
                if override_specs.get(hub_name, {}).get(venv_name, {}).get(package["name"]):
                    continue

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
    """Get the repo name for a whl."""

    return "whl__{}__{}".format(
        package["name"],
        whl["hash"][len("shasum:"):][:8],
    )

def _raw_whl_repos(_module_ctx, lock_specs, override_specs):
    repo_defs = {}

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                # This is an overridden package, don't declare repos for it
                if override_specs.get(hub_name, {}).get(venv_name, {}).get(package["name"]):
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

                    # print("Creating whl repo", name)
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
    """Get the repo name for a sdist build."""

    return "sbuild__{}__{}__{}".format(
        hub,
        venv,
        package["name"],
    )

def _venv_target(hub_name, venv, package_name):
    """Get the venv hub spoke for a given package."""

    return "{}//{}".format(
        _venv_hub_name(hub_name, venv),
        package_name,
    )

def _sbuild_repos(_module_ctx, lock_specs, annotation_specs, override_specs):
    """
    Lay down sdist build repos for each configured sdist.
    """

    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                # This is an overridden package, don't declare a repo for it
                if override_specs.get(hub_name, {}).get(venv_name, {}).get(package["name"]):
                    continue

                if "sdist" not in package:
                    continue

                name = _sbuild_repo_name(hub_name, venv_name, package)

                venv_anns = annotation_specs.get(hub_name, {}).get(venv_name, _default_annotations)
                build_deps = venv_anns.per_package.get(package["name"], {}).get("build-dependencies", [])

                # Per-package build deps, plus global defaults
                build_deps = {
                    it["name"]: it
                    for it in build_deps + venv_anns.default_build_deps
                }

                # print("Creating sdist repo", name)
                sdist_build(
                    name = name,
                    src = "@" + _sdist_repo_name(package) + "//file",
                    # FIXME: Add support for build deps and annotative build deps
                    deps = [
                        "@" + _venv_target(hub_name, venv_name, package["name"])
                        for package in build_deps.values()
                    ],
                )

def _whl_install_repo_name(hub, venv, package):
    """Get the whl install repo name for a given package."""

    return "whl_install__{}__{}__{}".format(
        hub,
        venv,
        package["name"],
    )

# TODO: Move this to a real library
def _parse_ini(lines):
    """
    Quick and dirty INI parser

    Handles basic INI format tables of key-value pairs, returning a dict.
    Ignores top level/sectionless keys.
    """
    dict = {}
    heading = None
    for line in lines.split("\n"):
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            heading = line[1:-2]
            dict[heading] = {}

        elif "=" in line and heading:
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            dict[heading][key] = value

    return dict

def _collect_entrypoints(module_ctx, lock_specs, annotation_specs):
    entrypoints = {}

    # Collect predeclared entrypoints
    for mod in module_ctx.modules:
        for it in mod.tags.declare_entrypoint:
            r = normalize_name(it.requirement)
            entrypoints.setdefault(r, {})

            # FIXME: Apply normalization here?
            entrypoints[r][it.name] = it.entrypoint

    # Collect entrypoints from annotation specifications
    for hub_name, venvs in annotation_specs.items():
        for venv_name, venv_struct in venvs.items():
            # print(hub_name, venv_name, venv_struct)
            for package_name, package in venv_struct.per_package.items():
                entrypoints.setdefault(package_name, {})
                scripts = package.get("entry-points", {}).get("console-scripts", {})
                for name, target in scripts.items():
                    # FIXME: Apply normalization here?
                    entrypoints[package_name][name] = target

    return entrypoints

def _whl_install_repos(module_ctx, lock_specs, override_specs):
    for hub_name, venvs in lock_specs.items():
        for venv_name, lock in venvs.items():
            for package in lock.get("package", []):
                # This is an overridden package, don't declare a repo for it
                if override_specs.get(hub_name, {}).get(venv_name, {}).get(package["name"]):
                    continue

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

                # print("Creating install repo", hub_name, venv_name, name)
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

def _marker_sha(marker):
    if marker:
        return sha1(marker)[:8]
    else:
        return None

def _group_repos(module_ctx, lock_specs, entrypoint_specs, override_specs):
    # Hub -> requirement -> venv -> True
    # For building hubs we need to know what venv configurations a given

    package_venvs = {}

    for hub_name, venvs in lock_specs.items():
        package_venvs[hub_name] = {}

        for venv_name, lock in venvs.items():
            # Index all the packages by name so activating extras is easy
            packages = {
                package["name"]: package
                for package in lock.get("package", [])
            }

            # Graph of {marker shasum: raw marker expr}
            markers = {}

            # Build a graph {name: {dependency_name: marker shasum}}
            graph = {}

            for name, package in packages.items():
                deps = {}

                if package.get("marker"):
                    fail("In venv %s package %s is marked which is unsupported" % (venv_name, package["name"]))

                # Enter the package into the venv internal graph
                graph.setdefault(package["name"], {})

                for d in package.get("dependencies", []):
                    marker = d.get("marker", "")
                    msha = _marker_sha(marker)

                    # If a marker expr is present, intern it
                    if msha:
                        markers[msha] = marker

                    # Add this dep to the set with the marker if any
                    graph[package["name"]][d["name"]] = msha

                    # Assume all extras are activated
                    extras = packages[d["name"]].get("optional-dependencies", {})
                    for extra in d.get("extra", []):
                        for extra_dep in extras.get(extra, []):
                            # This should never happen, but if we do have a
                            # reference in an extra to an inactive package we
                            # want to ignore it.
                            if extra_dep["name"] not in packages:
                                continue

                            graph.setdefault(d["name"], {})
                            marker = extra_dep.get("marker", "")
                            msha = _marker_sha(marker)

                            # If a marker expr is present, intern it
                            if msha:
                                markers[msha] = marker

                            # Add this dep to the set with the marker if any
                            graph[d["name"]][extra_dep["name"]] = msha

                # Enter the package into the venv hub manifest
                package_venvs[hub_name].setdefault(package["name"], {})
                package_venvs[hub_name][package["name"]][venv_name] = 1

            # So we can find sccs/clusters which need to co-occur
            # Note that we're assuming ALL marker conditional deps are live.
            cycle_groups = sccs({k: v.keys() for k, v in graph.items()})
            # print(hub_name, venv_name, graph, cycle_groups)

            # Now we can assign names to the sccs and collect deps. Note that
            # _every_ node in the graph will be in _a_ scc, those sccs are just
            # size 1 if the node isn't part of a cycle.
            #
            # Rather than trying to handle size-1 clusters separately which adds
            # implementation complexity we handle all clusters the same.
            named_sccs = {}
            scc_aliases = {}

            # scc id -> requirement -> marker IDs -> 1
            scc_markers = {}
            deps = {}
            for scc in cycle_groups:
                # Make up a deterministic name for the scc. What it is doesn't
                # matter. Could be gensym-style numeric too, but this is stable
                # to the cycle's content rather than the order of the lockfile.
                name = sha1(repr(scc))[:8]
                deps[name] = {}
                scc_markers[name] = {}
                named_sccs[name] = scc

                for node in scc:
                    # Mark scc component with an alias
                    scc_aliases[node] = name

                    # Mark the scc as depending on this package because it does
                    deps[name][node] = 1

                    # We know we've never visited node before so this is an assign
                    scc_markers[name][node] = {}

                    # FIXME: we are PURPOSEFULLY ignoring the potential that the
                    # dependency on this package within the scc goes through a
                    # dependency edge with a marker. Dependencies within the scc
                    # are always activated. This may cause problems.
                    for it in scc:
                        marker = markers.get(node, {}).get(it)
                        if marker:
                            fail("In venv %s package %s and %s form a cycle which may be marker-conditional! This is not supported" % (venv_name, node, it))

                    # Collect deps of the component which are not in the scc. We
                    # use dict-to-one as a set because there could be multiple
                    # members of an scc which take a dependency on the same
                    # thing outside the scc.
                    for d in graph[node]:
                        # Copy in the marker from node -> d if any
                        marker = graph[node].get(d)
                        if marker:
                            scc_markers[name].setdefault(d, {})
                            scc_markers[name][d][marker] = 1

                        if d not in scc:
                            deps[name][d] = 1

            # Simplify the scc markers to scc -> dep -> list[marker id]
            scc_markers = {
                scc_id: {dep: markers.keys() for dep, markers in deps.items()}
                for scc_id, deps in scc_markers.items()
            }

            # TODO: How do we plumb markers through here? The packages
            # themselves may have markers. Furthermore dependencies ON the
            # packages may have markers.
            #
            # Reviewing some (hopefully representative) markers it seems
            # unlikely that cycles would activate _through_ marker/conditional
            # dependencies. That is a conditional dependency edge's activation
            # creates an otherwise absent cycle. The most common application of
            # markers is to implement platform support and compatibility deps.
            #
            # On this basis we _ASSUME_ that this will never happen and all we
            # need to do is implement conditionals

            # At this point we have mapped every package to an scc (possibly of
            # size 1) which it participates in, named those sccs, and identified
            # their direct dependencies beyond the scc. So we can just lay down
            # targets.
            name = _venv_hub_name(hub_name, venv_name)

            overrides = override_specs.get(hub_name, {}).get(venv_name, {})

            # print("Creating venv hub", name)
            venv_hub(
                name = name,
                aliases = scc_aliases,  # String dict
                markers = markers,  # String dict
                sccs = named_sccs,  # List[String] dict
                scc_markers = json.encode(scc_markers),  # Mangle to String
                deps = deps,  # List[String] dict
                installs = {
                    # Use an override symbol if one exists, otherwise use the whl install repo.
                    # Note that applying an override will cause the whl install to be elided.
                    package: str(overrides.get(package, _whl_install_repo_name(hub_name, venv_name, {"name": package})))
                    for package in sorted(graph.keys())
                },
                entrypoints = json.encode(entrypoint_specs),
            )

    return package_venvs

def _hub_repos(module_ctx, lock_specs, package_venvs, entrypoint_specs):
    for hub_name, packages in package_venvs.items():
        # print("Creating uv hub", hub_name)
        hub_repo(
            name = hub_name,
            hub_name = hub_name,
            venvs = lock_specs[hub_name].keys(),
            packages = {
                package: venvs.keys()
                for package, venvs in packages.items()
            },
            entrypoints = json.encode(entrypoint_specs),
        )

def _uv_impl(module_ctx):
    """
    And now for the easy bit.

    - Collect hub configurations
    - Collect venv configurations per hub
    - Collect and parse lockfiles per venv per hub
    - Collect annotations and overrides per venv and hub
    - Generate sdist fetches for every locked package
    - Generate sdist to whl builds for every locked package
    - Generate whl fetches for every locked package
    - Generate an install choosing between a sdist build and a prebuilt whl for every package
    - For each venv generate a hub over the installs of packages in that venv
    - For each hub generate a hub fanning out to the venvs which make up the hub

    Note that we also generate a config repo which is used to introspect the
    host platform and establish flag default values so the default configuration
    is appropriate for the host platform.

    """

    hub_specs = _parse_hubs(module_ctx)

    venv_specs = _parse_venvs(module_ctx, hub_specs)

    lock_specs = _parse_locks(module_ctx, venv_specs)

    annotation_specs = _parse_annotations(module_ctx, hub_specs, venv_specs)

    # Roll through all the configured wheels, collect & validate the unique
    # platform configurations so that we can go create an appropriate power set
    # of conditions.
    configurations = _collect_configurations(module_ctx, lock_specs)

    # Collect declared entrypoints for packages
    entrypoints = _collect_entrypoints(module_ctx, lock_specs, annotation_specs)

    # Roll through and collect overrides of requirements with targets
    override_specs = _parse_overrides(module_ctx, lock_specs)

    # Roll through and create sdist and whl repos for all configured sources
    # Note that these have no deps to this point
    _raw_sdist_repos(module_ctx, lock_specs, override_specs)
    _raw_whl_repos(module_ctx, lock_specs, override_specs)

    # Roll through and create per-venv sdist build repos
    _sbuild_repos(module_ctx, lock_specs, annotation_specs, override_specs)

    # Roll through and create per-venv whl installs
    #
    # Note that we handle entrypoints at the venv level NOT the install level.
    # This is because we handle cycle breaking and deps at the venv level, so we
    # can't just take a direct dependency on the installed whl in its
    # implementation repo.
    _whl_install_repos(module_ctx, lock_specs, override_specs)

    # Roll through and create per-venv group/dep layers
    package_venvs = _group_repos(module_ctx, lock_specs, entrypoints, override_specs)

    # Finally the hubs themselves are fully trivialized
    _hub_repos(module_ctx, lock_specs, package_venvs, entrypoints)

    configurations_hub(
        name = "aspect_rules_py_pip_configurations",
        configurations = configurations,
    )

    if features.external_deps.extension_metadata_has_reproducible:
        return module_ctx.extension_metadata(reproducible = True)

_hub_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
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
        "src": attr.label(mandatory = True),
    },
)

_annotations_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "venv_name": attr.string(mandatory = True),
        "src": attr.label(mandatory = True),
    },
)

_declare_entrypoint = tag_class(
    attrs = {
        "requirement": attr.string(mandatory = True),
        "name": attr.string(mandatory = True),
        "entrypoint": attr.string(mandatory = True),
    },
)

_override_requirement = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "venv_name": attr.string(mandatory = True),
        "requirement": attr.string(mandatory = True),
        "target": attr.label(mandatory = True),
    },
)

uv = module_extension(
    implementation = _uv_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "declare_venv": _venv_tag,
        "lockfile": _lockfile_tag,
        "unstable_annotate_requirements": _annotations_tag,
        "declare_entrypoint": _declare_entrypoint,
        "override_requirement": _override_requirement,
    },
)
