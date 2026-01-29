"""

"""

def _hub_impl(repository_ctx):
    extra_activations = json.decode(repository_ctx.attr.extra_activations)
    version_activations = json.decode(repository_ctx.attr.version_activations)

    # FIXME: all_requirements target
    repository_ctx.file("BUILD.bazel", """\
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@aspect_rules_py//uv/private:defs.bzl", "py_whl_library")

""".format())

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
    content = []
    content.append("""
load("@aspect_rules_py//uv/private:normalize_name.bzl", "normalize_name")

# We aren't compatible with this because it isn't constant over venvs.
# all_requirements = []

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements_by_package = {{}}

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements = all_whl_requirements_by_package.values()

# We aren't compatible with this because we don't offer separate data targets
# all_data_requirements = []

def requirement(name):
    return "@@{repo_name}//{{0}}:{{0}}".format(normalize_name(name))
""".format(
        repo_name = repository_ctx.name,
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
load("//:defs.bzl", "compatible_with")
""",
        ]

        # TODO: Cheating
        # Need to deal with there being multiple package versions in the cfg
        # Need to deal with there being markers on a package in the cfg
        select_spec = {
            "//venv:{}".format(cfg): list(versions.keys())[0]
            for cfg, versions in specs.items()
        }

        error = "Available only in venvs: " + ", ".join([it.split(":")[1] for it in select_spec.keys()])

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
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:public"],
)
""".format(
                name = name,
                lib_select = repr(select_spec),
                whl_select = repr({k: v.split(":")[0] + ":whl" for k, v in select_spec.items()}),
                compat = repr(specs.keys()),
                error = error,
            ),
        )

        repository_ctx.file(name + "/BUILD.bazel", content = "\n".join(content))

uv_hub = repository_rule(
    implementation = _hub_impl,
    attrs = {
        "configurations": attr.string_list(),
        "extra_activations": attr.string(),
        "version_activations": attr.string(),
    },
)
