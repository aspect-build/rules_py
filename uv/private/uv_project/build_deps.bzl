"""Render a build-dependency graph in a project or source-build repository."""

load("//uv/private/pprint:defs.bzl", "indent", "pprint")

def _unresolved_build_requirement_impl(ctx):
    fail("Build requirement '{}' has multiple locked versions without disjoint resolution markers.".format(ctx.attr.requirement))

unresolved_build_requirement = rule(
    implementation = _unresolved_build_requirement_impl,
    attrs = {"requirement": attr.string(mandatory = True)},
)

def _safe_name(s):
    """Project a label or package string into a target-name-safe string."""
    return "".join([c if c.isalnum() or c in "._-" else "_" for c in s.elems()])

def write_build_deps(repository_ctx, packages, scc_graph, marker_fn = None):
    """Write the build requirements and their SCC dependency graph.

    Args:
        repository_ctx: Repository context receiving the generated BUILD files.
        packages: Package names mapped to candidates with deps (install and SCC
            labels) and markers (the resolution markers selecting that version).
        scc_graph: SCC identifiers mapped to member labels and marker expressions.
        marker_fn: Optional callback that interns markers in the caller's table.
            Without it, conditional members use markers and an empty fallback
            generated in this repository.
    """
    marker_table = {}

    def _marker(expr):
        if marker_fn != None:
            return marker_fn(expr)
        if expr not in marker_table:
            marker_table[expr] = "marker_{}".format(len(marker_table))
        return "//private/markers:" + marker_table[expr]

    needs_empty = False
    content = ["""\
load("@aspect_rules_py//py:defs.bzl", "py_library")
"""]
    for scc_id, members in scc_graph.items():
        deps = []
        for member, markers in members.items():
            if "" in markers:
                deps.append(member)
                continue

            needs_empty = True
            cases = {_marker(marker): member for marker in markers.keys()}
            cases["//conditions:default"] = "//private/sccs:empty"
            cond_id = "_maybe__{}__{}".format(scc_id, _safe_name(member))
            content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//:__subpackages__"],
)
""".format(
                name = cond_id,
                arms = indent(pprint(cases), " " * 4).lstrip(),
            ))
            deps.append(":" + cond_id)
        content.append("""
py_library(
    name = "{name}",
    deps = {deps},
    visibility = ["//:__subpackages__"],
)
""".format(
            name = scc_id,
            deps = indent(pprint(deps), " " * 4).lstrip(),
        ))
    repository_ctx.file("private/build_deps/sccs/BUILD.bazel", "\n".join(content))

    content = ["""\
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@aspect_rules_py//uv/private/uv_project:build_deps.bzl", "unresolved_build_requirement")
"""]
    for package, candidates in packages.items():
        arms = {}
        ambiguous = False
        for candidate in candidates:
            markers = candidate["markers"]
            if "" in markers:
                if len(candidates) > 1:
                    ambiguous = True
                markers = {"": 1}
            for marker in sorted(markers):
                condition = _marker(marker) if marker else "//conditions:default"
                if condition in arms and arms[condition] != candidate["deps"]:
                    ambiguous = True
                arms[condition] = candidate["deps"]

        if ambiguous:
            # Unrelated runtime groups can use a multi-version lock without
            # requesting this ambiguous build requirement.
            content.append("""
unresolved_build_requirement(
    name = {name},
    requirement = {name},
    visibility = ["//visibility:public"],
)
""".format(name = repr(package)))
            continue

        # Select the requested install and its closure together. The install
        # must remain direct even when a cycle reaches it conditionally.
        if len(arms) == 1 and "//conditions:default" in arms:
            deps = indent(pprint(arms["//conditions:default"]), " " * 4).lstrip()
        else:
            deps = "select({}, no_match_error = {})".format(
                indent(pprint(arms), " " * 4).lstrip(),
                repr("No locked version of build requirement '{}' matches the current Python/platform configuration.".format(package)),
            )
        content.append("""
py_library(
    name = "{name}",
    deps = {deps},
    visibility = ["//visibility:public"],
)
""".format(
            name = package,
            deps = deps,
        ))
    repository_ctx.file("private/build_deps/BUILD.bazel", "\n".join(content))

    if marker_fn != None:
        return

    if needs_empty:
        repository_ctx.file("private/sccs/BUILD.bazel", """\
load("@aspect_rules_py//py:defs.bzl", "py_library")

py_library(
    name = "empty",
    srcs = [],
    deps = [],
    imports = [],
    visibility = ["//:__subpackages__"],
)
""")

    if marker_table:
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
