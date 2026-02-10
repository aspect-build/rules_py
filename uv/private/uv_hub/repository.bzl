"""

"""

load("//uv/private/pprint:defs.bzl", "pprint")
load("//uv/private:sha1.bzl", "sha1")

def indent(text, space = " "):
    return "\n".join(["{}{}".format(space, l) for l in text.splitlines()])

def _hub_impl(repository_ctx):
    """Generates the central hub repository that exposes resolved dependencies to the build.

    This rule consumes the final, resolved dependency graph (encoded in the
    `extra_activations` and `version_activations` JSON attributes) and creates the
    user-facing API for depending on Python packages.

    For each Python package in the resolved graph, this rule generates:
    1.  A package (a directory with a `BUILD.bazel` file) named after the
        Python package (e.g., `requests/`).
    2.  Inside the `BUILD.bazel` file, a primary `alias` target (e.g.,
        `@pip//requests`) that `select()`s on the active virtual environment
        configuration (`:venv`). This resolves to a configuration-specific
        `py_library` that has the correct transitive dependencies for that venv.
    3.  A `defs.bzl` file containing `compatible_with` and `incompatible_with`
        helper functions. Users can use these in the `target_compatible_with`
        attribute of their `py_binary` or `py_test` to ensure they are built
        against a specific, compatible virtual environment.
    4.  A `requirements.bzl` file for partial compatibility with `rules_python`'s
        `requirement()` macro.

    Args:
        repository_ctx: The repository context.
    """
    extra_activations = json.decode(repository_ctx.attr.extra_activations)
    version_activations = json.decode(repository_ctx.attr.version_activations)

    marker_table = {}

    build_content = """\
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@aspect_rules_py//uv/private:defs.bzl", "py_whl_library", "whl_requirements")
"""
    
    select_clauses = []
    for cfg in repository_ctx.attr.configurations:
        packages_in_config = [
            "//{}:lib".format(name)
            for name, specs in version_activations.items()
            if cfg in specs
        ]
        
        build_content += """
filegroup(
    name = "all_requirements_{cfg}",
    srcs = {packages},
    visibility = ["//visibility:private"],
)
""".format(cfg = cfg, packages = repr(packages_in_config))

        select_clauses.append("        \"//venv:{cfg}\": [\":all_requirements_{cfg}\"]".format(cfg = cfg))

    build_content += """
filegroup(
    name = "all_requirements",
    srcs = select({{\n{select_clauses},\n        "//conditions:default": [],\n    }}),
    visibility = ["//visibility:public"],
)

whl_requirements(
    name = "all_whl_requirements",
    srcs = [":all_requirements"],
    visibility = ["//visibility:public"],
)
""".format(select_clauses = ",\n".join(select_clauses))

    repository_ctx.file("BUILD.bazel", build_content)

    ################################################################################
    content = [
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    ################################################################################
    content = [
        """\
# FIXME

alias(
    name = "venv",
    actual = "@aspect_rules_py//uv/private/constraints/venv:venv"
)
""",
    ]

    # Lay down the venv config settings
    for name in repository_ctx.attr.configurations:
        content.append(
            """
config_setting(
    name = "{0}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/venv:venv": "{0}",
    }},
    visibility = ["//visibility:public"],  # So that compatible_with is usable from other repos
)
""".format(name),
        )
    repository_ctx.file("venv/BUILD.bazel", content = "\n".join(content))

    ################################################################################
    # Lay down some new-style stuff
    content = [
        "# FIXME ",
    ]

    content.append(
        """
VIRTUALENVS = {configurations}
_repo = {repo_name}

def compatible_with(venvs, extra_constraints = []):
  for v in venvs:
    if v not in VIRTUALENVS:
      fail("Errant virtualenv reference %r" % v)

  return {{
    Label("//venv:" + it): extra_constraints
    for it in venvs
  }} | {{
    "//conditions:default": ["@platforms//:incompatible"],
  }}

def incompatible_with(venvs, extra_constraints = []):
  for v in venvs:
    if v not in VIRTUALENVS:
      fail("Errant virtualenv reference %r" % v)

  return {{
    Label("//venv:" + it): ["@platforms//:incompatible"]
    for it in venvs
  }} | {{
    "//conditions:default": extra_constraints,
  }}
""".format(
            configurations = repository_ctx.attr.configurations,
            repo_name = repr(repository_ctx.name),
        ),
    )

    repository_ctx.file("defs.bzl", content = "\n".join(content))

    ################################################################################
    # Lay down a requirements.bzl for compatibility with rules_python
    all_requirements = [name for name, specs in version_activations.items()]
    content = []
    content.append('''
load("@aspect_rules_py//uv/private:normalize_name.bzl", "normalize_name")

all_requirements = {all_requirements}

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements_by_package = {{}}

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements = all_whl_requirements_by_package.values()

# We aren't compatible with this because we don't offer separate data targets
# all_data_requirements = []

def requirement(name):
    return "@@{repo_name}//{{0}}:{{0}}".format(normalize_name(name))
'''.format(
        repo_name = repository_ctx.name,
        all_requirements = repr(all_requirements),
    ))
    repository_ctx.file("requirements.bzl", content = "\n".join(content))

    ################################################################################
    # Lay down the hub aliases

    entrypoints = {}

    # FIXME: since we're creating a package per target, we may have to implement
    # name mangling to ensure that the pip packages become valid Bazel packages.
    for name, specs in version_activations.items():
        content = [
            """
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@aspect_rules_py//uv/private:defs.bzl", "py_whl_library")
load("//:defs.bzl", "compatible_with")
""",
        ]

        cfgs = {}
        extra_targets = {}

        for cfg, versions in specs.items():
            if len(versions.keys()) > 1:
                fail("Error: Package {} has multiple versions in configuration {}; cowardly failing to configure this graph".format(name, cfg))

            version = list(versions.keys())[0]

            deps = []
            for extra, markers in extra_activations.get(version, {}).get(cfg, {}).items():
                if "" not in markers:
                    extra_name = "_extra_{}".format(sha1(extra + repr(markers))[:16])
                    deps.append(":" + extra_name)
                    if extra_name in extra_targets:
                        continue

                    arms = {}
                    for marker in markers.keys():
                        if marker not in marker_table:
                            id = sha1(marker)
                            marker_table[marker] = id
                        else:
                            id = marker_table[marker]

                        marker_condition = "//private/markers:" + id
                        arms[marker_condition] = extra

                    extra_targets[extra_name] = 1
                    content.append("""
# Implementation of {extra} markers
#
{markers_comment}
#
alias(
    name = "{name}",
    actual = select({select}),
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:private"],
)
""".format(
                        extra = extra,
                        markers_comment = indent(pprint(markers.keys()), "#   "),
                        name = extra_name,
                        select = indent(pprint(arms), "    ").lstrip(),
                        compat = repr(cfgs.keys()),
                    ))

                else:
                    deps.append(extra)

            cfg_name = "_cfg_{}".format(cfg)
            cfgs[cfg] = cfg_name
            content.append("""
py_library(
    name = "{}",
    deps = {},
    visibility = ["//visibility:private"],
)
""".format(cfg_name, indent(pprint(deps), "    ").lstrip()))

        select_spec = {
            "//venv:{}".format(cfg): ":" + cfgs[cfg]
            for cfg in specs.keys()
        }

        error = "Available only in venvs: " + ", ".join([it.split(":")[1] for it in select_spec.keys()])

        # TODO: Find a way to add a dist-info target here
        # TODO: Find a way to add entrypoint targets here?
        # TODO: Add a way to take a "soft" dependency here?
        # TODO: Add the wheel graph back in here
        content.append(
            """
# This target is for a "hard" dependency.
# Dependencies on this target will cause build failures if it's unavailable.
alias(
    name = "lib",
    actual = "{name}",
    visibility = ["//visibility:public"],
)
py_whl_library(
    name = "whl",
    srcs = [":{name}"],
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
""".format(
                name = name,
                lib_select = indent(pprint(select_spec), "      ").lstrip(),
                compat = repr(specs.keys()),
                error = error,
            ),
        )

        repository_ctx.file(name + "/BUILD.bazel", content = "\n".join(content))

    ################################################################################
    # Finally we have to lay down the marker tests

    # FIXME: This will duplicate conditions in the individual venvs
    # But doing it this way decouples the implementations
    content = ["""
load("@aspect_rules_py//uv/private/markers:defs.bzl", "decide_marker")
"""]

    for marker_expr, marker_id in marker_table.items():
        content.append("""
decide_marker(
    name = "{name}",
    marker = {marker},
    visibility = ["//:__subpackages__"],
)
""".format(name = marker_id, marker = repr(marker_expr)))

    repository_ctx.file("private/markers/BUILD.bazel", "\n".join(content))

uv_hub = repository_rule(
    implementation = _hub_impl,
    attrs = {
        "configurations": attr.string_list(),
        "extra_activations": attr.string(),
        "version_activations": attr.string(),
    },
)
