VIRTUALENVS = [
    "single_project_hub",
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
    "single_project_hub": [
        "@@aspect_rules_py++uv+pypi_single//cowsay:pkg",
        "@@aspect_rules_py++uv+pypi_single//single_project_hub:pkg",
    ],
}

_GROUP_DEP_LABELS = {
    group: [Label(dep) for dep in deps]
    for group, deps in _DEPS_BY_GROUP.items()
}

_GROUP_DEPS = select(
    {
        Label("//dep_group:" + group): deps
        for group, deps in _GROUP_DEP_LABELS.items()
    },
    no_match_error = "no dep_group selected; set the dep_group attribute on the consuming target to one of: single_project_hub",
)

def group_deps_for(group):
    if group not in _GROUP_DEP_LABELS:
        fail("unknown dep_group %r; expected one of: %s" % (group, ", ".join(sorted(_GROUP_DEP_LABELS))))
    return _GROUP_DEP_LABELS[group]

def group_deps():
    return _GROUP_DEPS
