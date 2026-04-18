load("//uv/private/pprint:defs.bzl", "pprint")

def indent(text, space = "    "):
    return "\n".join(["{}{}".format(space, l) for l in text.splitlines()])

def _hub_impl(repository_ctx):
    """Generates the central hub repository that exposes resolved dependencies to the build.

    - Defines a helper alias for configuring the active [dependency-group]
    - Defines aliases for every package in any component project

    This "surface" hub is dead easy, as it just wraps up project hubs which are
    responsible for all the heavy lifting.

    Args:
        repository_ctx: The repository context.
    """

    packages = json.decode(repository_ctx.attr.packages)

    content = [
        """\
alias(
    name = "venv",
    actual = "@aspect_rules_py//uv/private/constraints/venv:venv",
    visibility = ["//visibility:public"],
)
""",
    ]

    for name in repository_ctx.attr.configurations:
        content.append(
            """
config_setting(
    name = "{name}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/venv:venv": "{name}",
    }},
    visibility = ["//visibility:public"],
)
""".format(name = name),
        )
    repository_ctx.file("venv/BUILD.bazel", content = "\n".join(content))

    content = [
        """\
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@aspect_rules_py//uv/private:defs.bzl", "py_whl_library", "whl_requirements")
""",
    ]

    index_select_clauses = {
        "//venv:" + cfg: ["@{}//:gazelle_index_whls".format(project_id)]
        for cfg, project_id in repository_ctx.attr.configurations.items()
    }

    content.append("""
filegroup(
    name = "gazelle_index_whls",
    srcs = select({index_select_clauses},
    ),
    visibility = ["//visibility:public"],
)
""".format(index_select_clauses = indent(pprint(index_select_clauses), "        ").lstrip()))

    repository_ctx.file("BUILD.bazel", "\n".join(content))

    entrypoints = {}

    for package_name, specs in packages.items():
        content = [
            """\
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@aspect_rules_py//uv/private:defs.bzl", "py_whl_library")
load("//:defs.bzl", "compatible_with")
""",
        ]

        select_spec = {
            "//venv:{}".format(cfg): l
            for cfg, l in specs.items()
        }

        error = "Available only in venvs: " + ", ".join(specs.keys())  # Simplified error string

        if len(specs) == 1:
            select_spec["//conditions:default"] = list(specs.values())[0]

        # FIXME: Add support for entrypoints?
        # FIXME: Create a narrower dist-info rule
        if len(specs) == 1:
            alias_template = """
alias(
    name = "{name}",
    actual = select({lib_select}),
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:public"],
)
"""
        else:
            alias_template = """
alias(
    name = "{name}",
    actual = select({lib_select},
        no_match_error = "{error}",
    ),
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:public"],
)
"""

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
""".format(name = package_name) + alias_template.format(
                name = package_name,
                lib_select = indent(pprint(select_spec), "      ").lstrip(),
                compat = repr(specs.keys()),
                error = error,
            ),
        )

        repository_ctx.file(package_name + "/BUILD.bazel", content = "\n".join(content))

    content = [
        """
VIRTUALENVS = {configurations}
_repo = {repo_name}

def compatible_with(venvs, extra_constraints = []):
  for v in venvs:
    if v not in VIRTUALENVS:
      fail("Errant virtualenv reference %r" % v)

  result = {{
    Label("//venv:" + it): extra_constraints
    for it in venvs
  }}
  if len(venvs) == 1:
    result["//conditions:default"] = extra_constraints
  else:
    result["//conditions:default"] = ["@platforms//:incompatible"]
  return result

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
            configurations = pprint(repository_ctx.attr.configurations.keys()),
            repo_name = repr(repository_ctx.name),
        ),
    ]

    repository_ctx.file("defs.bzl", content = "\n".join(content))

    repository_ctx.file("python_version.bzl", content = """PYTHON_VERSION = "{python_version}"
""".format(
        python_version = repository_ctx.attr.python_version,
    ))

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

    entrypoints = {}

uv_hub = repository_rule(
    doc = """
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
        "python_version": attr.string(
            doc = """
            Python version used for uv lock resolution.
            """,
        ),
    },
)
