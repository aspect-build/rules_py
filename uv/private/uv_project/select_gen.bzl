"""Helpers for building select() arm dicts used in hub alias generation."""

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
