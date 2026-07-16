"""

"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("//uv/private/pprint:defs.bzl", "indent", "pprint")

def _hub_impl(repository_ctx):
    """Generates the central hub repository that exposes resolved dependencies to the build.

    - Defines a helper alias for configuring the active [dependency-group]
    - Defines aliases for every package in any component project

    This "surface" hub is dead easy, as it just wraps up project hubs which are
    responsible for all the heavy lifting.

    Args:
        repository_ctx: The repository context.
    """

    # {requirement: {cfg: target}}
    packages = json.decode(repository_ctx.attr.packages)
    package_names = sorted(packages.keys())

    ################################################################################
    # Lay down the //dep_group:BUILD.bazel file with config flags
    #
    # We do this first because everything else hangs off of these config_settings.
    content = [
        """\
alias(
    name = "dep_group",
    actual = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group",
    visibility = ["//visibility:public"],
)
""",
    ]

    # Lay down the dep_group config settings
    for name in repository_ctx.attr.configurations:
        content.append(
            """
config_setting(
    name = "{name}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/dep_group:dep_group": "{name}",
    }},
    visibility = ["//visibility:public"],
)
""".format(name = name),
        )
    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""")
    repository_ctx.file("dep_group/BUILD.bazel", content = "\n".join(content))

    ################################################################################
    # Lay down the //:BUILD.bazel file
    content = []

    index_select_clauses = {
        "//dep_group:" + cfg: ["@{}//:gazelle_index_whls".format(project_id)]
        for cfg, project_id in repository_ctx.attr.configurations.items()
    }

    content.append("""\
filegroup(
    name = "gazelle_index_whls",
    srcs = select({index_select_clauses},
    ),
    visibility = ["//visibility:public"],
)

exports_files(
    ["defs.bzl", "requirements.bzl"],
    visibility = ["//visibility:public"],
)
""".format(index_select_clauses = indent(pprint(index_select_clauses), "        ").lstrip()))

    repository_ctx.file("BUILD.bazel", "\n".join(content))

    ################################################################################
    # Lay down the hub aliases
    for package_name, specs in packages.items():
        content = [
            """\
load("//:defs.bzl", "compatible_with")
""",
        ]

        select_spec = {
            "//dep_group:{}".format(cfg): l
            for cfg, l in specs.items()
        }
        whl_select_spec = {
            "//dep_group:{}".format(cfg): l + "_whl"
            for cfg, l in specs.items()
        }

        error = "Available only in dep_groups: " + ", ".join(specs.keys())  # Simplified error string

        # When the package itself is named "pkg", the `:{name}` alias below already
        # exposes a `pkg` target — emitting a separate `:pkg` alias would collide.
        pkg_alias = "" if package_name == "pkg" else """\
alias(
    name = "pkg",
    actual = "{name}",
    visibility = ["//visibility:public"],
)
""".format(name = package_name)

        # FIXME: Add support for entrypoints?
        # FIXME: Create a narrower dist-info rule
        content.append(
            """
# This target is for a "hard" dependency.
# Dependencies on this target will cause build failures if it's unavailable.
alias(
    name = "lib",
    actual = "{name}",
    visibility = ["//visibility:public"],
)
{pkg_alias}\
alias(
    name = "whl",
    actual = select({whl_select}),
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:public"],
)
filegroup(
    name = "dist_info",
    srcs = [":{name}"],
    visibility = ["//visibility:public"],
)
alias(
    name = "{name}",
    actual = select({lib_select},
        no_match_error = "{error}",
    ),
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:public"],
)

exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""".format(
                name = package_name,
                pkg_alias = pkg_alias,
                lib_select = indent(pprint(select_spec), "      ").lstrip(),
                whl_select = indent(pprint(whl_select_spec), "      ").lstrip(),
                compat = repr(specs.keys()),
                error = error,
            ),
        )

        repository_ctx.file(package_name + "/BUILD.bazel", content = "\n".join(content))

    ################################################################################
    # Lay down //:defs.bzl

    # Invert the sparse package->group membership (`packages` is keyed
    # {name: {group: target}}) into group->[canonical :pkg labels] in a single
    # pass, rather than rescanning every package once per group. Seed every
    # known group so a group with no packages still gets an (empty) select arm.
    deps_by_group = {group: [] for group in sorted(repository_ctx.attr.configurations)}
    for name in package_names:  # sorted, so each group's label list stays sorted
        label = "@@{}//{}:pkg".format(repository_ctx.name, name)
        for group in packages[name]:
            if group in deps_by_group:
                deps_by_group[group].append(label)

    # The emitted `_GROUP_DEPS` is a module-level select() built once at load.
    # Its keys use `Label(...)` so they resolve relative to this hub repo rather
    # than the consuming package that loads `group_deps()`.
    content = [
        """\
VIRTUALENVS = {configurations}

def compatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {{
        Label("//dep_group:" + it): extra_constraints
        for it in venvs
    }} | {{
        "//conditions:default": ["@platforms//:incompatible"],
    }}

def incompatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {{
        Label("//dep_group:" + it): ["@platforms//:incompatible"]
        for it in venvs
    }} | {{
        "//conditions:default": extra_constraints,
    }}

_DEPS_BY_GROUP = {deps_by_group}

_GROUP_DEP_LABELS = {{
    group: [Label(dep) for dep in deps]
    for group, deps in _DEPS_BY_GROUP.items()
}}

_GROUP_DEPS = select(
    {{
        Label("//dep_group:" + group): deps
        for group, deps in _GROUP_DEP_LABELS.items()
    }},
    no_match_error = {no_match_error},
)

def group_deps_for(group):
    if group not in _GROUP_DEP_LABELS:
        fail("unknown dep_group %r; expected one of: %s" % (group, ", ".join(sorted(_GROUP_DEP_LABELS))))
    return _GROUP_DEP_LABELS[group]

def group_deps():
    return _GROUP_DEPS
""".format(
            configurations = pprint(repository_ctx.attr.configurations.keys()),
            deps_by_group = pprint(deps_by_group),
            no_match_error = repr(
                "no dep_group selected; set the dep_group attribute on the consuming target to one of: " +
                ", ".join(sorted(repository_ctx.attr.configurations)),
            ),
        ),
    ]

    repository_ctx.file("defs.bzl", content = "\n".join(content))

    ################################################################################
    # Lay down a requirements.bzl for compatibility with rules_python. Keep this
    # file's surface aligned with rules_python's generated requirements.bzl; any
    # rules_py-specific additions belong in defs.bzl instead.
    content = []
    content.append("""
load("@aspect_rules_py//uv/private:normalize_name.bzl", "normalize_name")

all_requirements = {all_requirements}

all_whl_requirements_by_package = {all_whl_requirements_by_package}

all_whl_requirements = all_whl_requirements_by_package.values()

all_data_requirements = all_requirements

def requirement(name):
    return "@@{repo_name}//{{0}}:pkg".format(normalize_name(name))
""".format(
        all_requirements = repr([
            "@@{0}//{1}:pkg".format(repository_ctx.name, name)
            for name in package_names
        ]),
        all_whl_requirements_by_package = repr({
            name: "@@{0}//{1}:whl".format(repository_ctx.name, name)
            for name in package_names
        }),
        repo_name = repository_ctx.name,
    ))
    repository_ctx.file("requirements.bzl", content = "\n".join(content))

    if not features.external_deps.repo_metadata_has_reproducible:
        return None
    return repository_ctx.repo_metadata(reproducible = True)

uv_hub = repository_rule(
    doc = """
    Generates the surface hub repository exposed to the build.

    Lays down two loadable files:

    - `defs.bzl` (rules_py-native): the `group_deps()` and `group_deps_for()`
      helpers plus the `compatible_with` / `incompatible_with` constraint
      helpers and the `VIRTUALENVS` list.
    - `requirements.bzl`: a rules_python-compatibility shim (`all_requirements`,
      `requirement()`, and friends).

    `group_deps()` returns the dependency list for whichever dependency group
    the consuming target selects via its `dep_group` attribute. A hub spanning
    multiple projects has an `all_requirements` union whose members are
    incompatible under any single `dep_group`; `group_deps()` resolves instead
    to just the subset valid for the active group. Because `dep_group` drives an
    incoming transition, the returned `select()` is evaluated under the chosen
    group, so it is used directly without repeating the group name:

        deps = group_deps()

    It is a function rather than a value so that future options -- such as
    PEP 508 package extras -- can be added as keyword arguments without breaking
    callers.

    `group_deps_for(name)` returns the membership of one explicit group as
    sorted `Label` values, for macros that must inspect package names (via
    `Label.package`) during package loading or deliberately pin one group's
    deps. The aliases still resolve under the active `dep_group`, so a consuming
    target that uses these labels as `deps` must set the matching group itself.
    It is the only public accessor for the per-group membership; the underlying
    table is built once at load and shared with the `group_deps()` select.
    """,
    implementation = _hub_impl,
    attrs = {
        "configurations": attr.string_dict(
            doc = """
            Mapping of configuration name to a project _containing_ that configuration.
            """,
        ),
        "packages": attr.string(
            doc = """
            JSON blob mapping packages to configurations to projects.
            """,
        ),
    },
)
