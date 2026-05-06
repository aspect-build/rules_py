DEP_GROUPS = [
    "single_project_hub",
]
PROJECTS_BY_GROUP = {
    "single_project_hub": [
        "single_project_hub",
    ],
}
_repo = "aspect_rules_py++uv+pypi_single"

def compatible_with(groups, extra_constraints = []):
    for g in groups:
        if g not in PROJECTS_BY_GROUP:
            fail("Errant dep_group reference %r — known groups: %r" % (g, DEP_GROUPS))

    result = {}
    for grp in groups:
        for stamp in PROJECTS_BY_GROUP[grp]:
            result[Label("//dep_group:" + stamp + "__" + grp)] = extra_constraints
    result["//conditions:default"] = ["@platforms//:incompatible"]
    return result

def incompatible_with(groups, extra_constraints = []):
    for g in groups:
        if g not in PROJECTS_BY_GROUP:
            fail("Errant dep_group reference %r — known groups: %r" % (g, DEP_GROUPS))

    result = {}
    for grp in groups:
        for stamp in PROJECTS_BY_GROUP[grp]:
            result[Label("//dep_group:" + stamp + "__" + grp)] = ["@platforms//:incompatible"]
    result["//conditions:default"] = extra_constraints
    return result

_DEPS_BY_GROUP = {
    "": [
        "@@aspect_rules_py++uv+pypi_single//cowsay:pkg",
        "@@aspect_rules_py++uv+pypi_single//single_project_hub:pkg",
    ],
    "single_project_hub": [
        "@@aspect_rules_py++uv+pypi_single//cowsay:pkg",
        "@@aspect_rules_py++uv+pypi_single//single_project_hub:pkg",
    ],
}

_GROUP_DEP_LABELS = {
    group: [Label(dep) for dep in deps]
    for group, deps in _DEPS_BY_GROUP.items()
}

_GROUP_DEPS_RAW = {
    "//dep_group:single_project_hub__": [
        "@@aspect_rules_py++uv+pypi_single//cowsay:pkg",
        "@@aspect_rules_py++uv+pypi_single//single_project_hub:pkg",
    ],
    "//dep_group:single_project_hub__single_project_hub": [
        "@@aspect_rules_py++uv+pypi_single//cowsay:pkg",
        "@@aspect_rules_py++uv+pypi_single//single_project_hub:pkg",
    ],
}

_GROUP_DEPS = select(
    {
        Label(cfg): [Label(dep) for dep in deps]
        for cfg, deps in _GROUP_DEPS_RAW.items()
    },
    no_match_error = "no dep_group selected; set the dep_group attribute on the consuming target to one of: single_project_hub",
)

def group_deps_for(group):
    if group not in _GROUP_DEP_LABELS:
        fail("unknown dep_group %r; expected one of: %s" % (group, ", ".join(sorted(_GROUP_DEP_LABELS))))
    return _GROUP_DEP_LABELS[group]

def group_deps():
    return _GROUP_DEPS
