"""

"""

def _hub_impl(repository_ctx):
    # We get packages as {package: venvs}
    # Need to invert that
    venv_packages = {}
    for package, venvs in repository_ctx.attr.packages.items():
        for venv in venvs:
            venv_packages.setdefault(venv, [])
            venv_packages[venv].append("//{0}:{0}".format(package))

    # Build up a single target which depends on _all_ the packages in a given
    # venv configuration.
    #
    # TODO: Some packages in a venv configuration may be incompatible; figure
    # out how to make this take "soft" rather than "hard" dependencies.
    repository_ctx.file("BUILD.bazel", """\
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@aspect_rules_py//uv/private:defs.bzl", "py_whl_library")

py_library(
    name = "all_requirements",
    deps = select({lib_arms}),
    visibility = ["//visibility:private"],
)
py_whl_library(
    name = "all_whl_requirements",
    deps = [":all_requirements"],
    visibility = ["//visibility:public"],
)
""".format(lib_arms = {
        "//venv:{}".format(venv): pkgs
        for venv, pkgs in venv_packages.items()
    }))

    ################################################################################
    content = [
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for name, conditions in repository_ctx.attr.configurations.items():
        content.append(
            """\
selects.config_setting_group(
    name = "{}",
    match_all = {},
)
""".format(name, repr(conditions)),
        )

    repository_ctx.file("configuration/BUILD.bazel", content = "\n".join(content))

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
    for name in repository_ctx.attr.venvs:
        content.append(
            """
config_setting(
    name = "{0}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/venv:venv": "{0}",
    }},
    visibility = ["//:__subpackages__"],
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
VIRTUALENVS = {venvs}

PACKAGES = {venv_packages}

def _compatible_with(venvs, extra_constraints = []):
  return select({{
    Label("//venv:" + it): extra_constraints
    for it in venvs
  }} | {{
    "//conditions:default": ["@platforms//:incompatible"],
  }})

pip = struct(
  compatible_with = _compatible_with,
)
""".format(
            venvs = repr(repository_ctx.attr.venvs),
            venv_packages = repr(venv_packages),
        ),
    )

    repository_ctx.file("defs.bzl", content = "\n".join(content))

    ################################################################################
    # Lay down a requirements.bzl for compatibility with rules_python
    content = []
    content.append("""
load("@rules_python//python:pip.bzl", "pip_utils")

# We arne't compatible with this because it isn't constant over venvs.
# all_requirements = []

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements_by_package = {{}}

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements = all_whl_requirements_by_package.values()

# We aren't compatible with this because we don't offer separate data targets
# all_data_requirements = []

def requirement(name):
    return "@@{repo_name}//{{0}}:{{0}}".format(pip_utils.normalize_name(name))
""".format(
        repo_name = repository_ctx.name,
    ))
    repository_ctx.file("requirements.bzl", content = "\n".join(content))

    ################################################################################
    # Lay down the hub aliases

    entrypoints = json.decode(repository_ctx.attr.entrypoints)

    # FIXME: since we're creating a package per target, we may have to implement
    # name mangling to ensure that the pip packages become valid Bazel packages.
    for name, spec in repository_ctx.attr.packages.items():
        content = [
            """
load("//:defs.bzl", "pip")
""",
        ]

        select_spec = {
            "//venv:{}".format(it): "@venv__{0}__{1}//{2}:{2}".format(repository_ctx.attr.hub_name, it, name)
            for it in spec
        }
        error = "Available only in venvs " + ", ".join([it.split(":")[1][1:] for it in select_spec.keys()])

        # TODO: Find a way to add a dist-info target here
        # TODO: Find a way to add entrypoint targets here?
        # TODO: Add a way to take a "soft" dependency here?
        content.append(
            """
# This target is for a "hard" dependency.
# Dependencies on this target will cause build failures if it's unavailable.
alias(
    name = "lib",
    actual = "{name}",
    visibility = ["//visibility:public"],
)
alias(
    name = "{name}",
    actual = select(
      {lib_select},
      no_match_error = "{error}",
    ),
    target_compatible_with = pip.compatible_with({compat}),
    visibility = ["//visibility:public"],
)
alias(
    name = "whl",
    actual = select(
      {whl_select},
      no_match_error = "{error}",
    ),
    target_compatible_with = pip.compatible_with({compat}),
    visibility = ["//visibility:public"],
)
""".format(
                name = name,
                lib_select = repr(select_spec),
                whl_select = repr({k: v.split(":")[0] + ":whl" for k, v in select_spec.items()}),
                compat = repr(spec),
                error = error,
            ),
        )

        repository_ctx.file(name + "/BUILD.bazel", content = "\n".join(content))

        content = [
            """load("//:defs.bzl", "pip")""",
        ]
        for entrypoint_name, entrypoint_coordinate in entrypoints.get(name, {}).items():
            select_spec = {
                "//venv:{}".format(it): "@venv__{0}__{1}//{2}/entrypoints:{3}".format(repository_ctx.attr.hub_name, it, name, entrypoint_name)
                for it in spec
            }

            content.append(
                """
alias(
    name = "{name}",
    actual = select(
      {select},
      no_match_error = "{error}",
    ),
    target_compatible_with = pip.compatible_with({compat}),
    visibility = ["//visibility:public"],
)
""".format(
                    name = entrypoint_name,
                    select = repr(select_spec),
                    compat = repr(spec),
                    error = error,
                ),
            )

        repository_ctx.file(name + "/entrypoints/BUILD.bazel", content = "\n".join(content))

hub_repo = repository_rule(
    implementation = _hub_impl,
    attrs = {
        "hub_name": attr.string(),
        "venvs": attr.string_list(),
        "packages": attr.string_list_dict(),
        "configurations": attr.string_list_dict(),
        "entrypoints": attr.string(
            doc = """
        JSON encoded map of pkg -> entrypoint -> coordinate
        """,
        ),
    },
)
