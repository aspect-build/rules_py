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
