"""Helpers for generating select()-based aliases and their markers."""

load("//uv/private/pprint:defs.bzl", "indent", "pprint")

# Selected by aliases when no marker matches. Visibility must be
# //:__subpackages__ because those aliases live in //:.
EMPTY_LIBRARY = """\
load("@aspect_rules_py//py:defs.bzl", "py_library")

py_library(
    name = "empty",
    srcs = [],
    deps = [],
    imports = [],
    visibility = ["//:__subpackages__"],
)
"""

def safe_name(s):
    """Project a label or package string into a target-name-safe string."""
    return "".join([c if c.isalnum() or c in "._-" else "_" for c in s.elems()])

def marker_interner(marker_table):
    """Return a marker_fn interning expressions into `marker_table` as //private/markers labels."""

    def _marker(expr):
        if expr not in marker_table:
            marker_table[expr] = "marker_{}".format(len(marker_table))
        return "//private/markers:" + marker_table[expr]

    return _marker

def write_markers(repository_ctx, marker_table):
    """Lay down the decide_marker() targets for an interned marker table."""
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
    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""")
    repository_ctx.file("private/markers/BUILD.bazel", "\n".join(content))

def conditional_dep(content, dep, markers, cond_id, marker_fn, no_match):
    """Return `dep` when unconditional, else append a select() alias to `content` and return its label."""
    if "" in markers:
        return dep
    cases = {marker_fn(marker): dep for marker in markers}
    cases["//conditions:default"] = no_match
    content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//:__subpackages__"],
)
""".format(name = cond_id, arms = indent(pprint(cases), " " * 4).lstrip()))
    return ":" + cond_id

def build_package_select_arms(scc_cfgs, scc_graph, package, marker_fn):
    """Build cfg_arms and whl_cfg_arms for a single per-dep-group package alias.

    Args:
        scc_cfgs:   {scc_id: {marker_expr: 1}} — SCCs this package belongs to
                    under the current dep-group config, each annotated with the
                    marker expressions that activate the SCC ("" = always active).
        scc_graph:  {scc_id: {install_label: {marker: 1}}} — used to discover
                    underlying whl_install labels by substring match on package name.
        package:    Normalized package name (e.g. "iniconfig").
        marker_fn:  str → str — converts a raw marker expression into its
                    corresponding config_setting label.

    Returns:
        (cfg_arms, whl_cfg_arms) — both are {label: target} dicts suitable for
        select(). Both are guaranteed to contain a "//conditions:default" arm so
        the select() is always total (Bazel rejects non-total alias selects).

        For packages that are exclusively marker-gated (no unconditional SCC),
        the default arms point at the empty-SCC fallback and :empty_whl,
        making inactive deps a no-op instead of a build failure.
    """
    cfg_arms = {}
    whl_cfg_arms = {}

    for scc, markers in scc_cfgs.items():
        whl_for_pkg = None
        for install_label in scc_graph.get(scc, {}).keys():
            if ("__" + package + "__") in install_label:
                whl_for_pkg = install_label.replace(":install", ":whl")
                break

        if "" in markers:
            if "//conditions:default" in cfg_arms:
                fail("Configuration conflict: package '{}' has more than one unconditional SCC".format(package))
            cfg_arms["//conditions:default"] = "//private/sccs:" + scc
            if whl_for_pkg:
                whl_cfg_arms["//conditions:default"] = whl_for_pkg
        else:
            for marker in markers.keys():
                ml = marker_fn(marker)
                if ml in cfg_arms:
                    fail("Configuration conflict: package '{}' has two SCCs for marker '{}'".format(package, marker))
                cfg_arms[ml] = "//private/sccs:" + scc
                if whl_for_pkg:
                    whl_cfg_arms[ml] = whl_for_pkg

    if "//conditions:default" not in cfg_arms:
        cfg_arms["//conditions:default"] = "//private/sccs:empty"

    if "//conditions:default" not in whl_cfg_arms:
        whl_cfg_arms["//conditions:default"] = ":empty_whl"

    return cfg_arms, whl_cfg_arms
