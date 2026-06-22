VIRTUALENVS = [
    "dev",
    "unit-tests",
    "beta",
    "gamma",
]

def compatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {
        Label("//dep_group:" + it): extra_constraints
        for it in venvs
    } | {
        "//conditions:default": ["@platforms//:incompatible"],
    }

def incompatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {
        Label("//dep_group:" + it): ["@platforms//:incompatible"]
        for it in venvs
    } | {
        "//conditions:default": extra_constraints,
    }

_DEPS_BY_GROUP = {
    "beta": [
        "@@aspect_rules_py++uv+pypi_multi//beta:pkg",
        "@@aspect_rules_py++uv+pypi_multi//cowsay:pkg",
    ],
    "dev": [
        "@@aspect_rules_py++uv+pypi_multi//cowsay:pkg",
    ],
    "gamma": [
        "@@aspect_rules_py++uv+pypi_multi//cowsay:pkg",
        "@@aspect_rules_py++uv+pypi_multi//gamma:pkg",
    ],
    "unit-tests": [
        "@@aspect_rules_py++uv+pypi_multi//cowsay:pkg",
    ],
}

_GROUP_DEPS = select(
    {
        Label("//dep_group:" + group): deps
        for group, deps in _DEPS_BY_GROUP.items()
    },
    no_match_error = "no dep_group selected; set the dep_group attribute on the consuming target to one of: beta, dev, gamma, unit-tests",
)

def group_deps():
    return _GROUP_DEPS
