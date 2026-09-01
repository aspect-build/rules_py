load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/extension:graph_utils.bzl", "activate_extras", "collect_build_deps", "collect_sccs", "exclude_build_dep", "reachable_build_deps")

def _extras_test_impl(ctx):
    env = unittest.begin(ctx)

    # Common configuration for tests
    cfg = "default"

    # Test Case 1: Simple extra activation
    # pkg1[__base__] depends on pkg2[foo_extra]
    # pkg2[foo_extra] implies dep on pkg3[__base__]
    marker_graph_1 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "__base__"): {"": 1},
            ("proj", "1.0", "pkg2", "foo_extra"): {"": 1},
        },
        ("proj", "1.0", "pkg2", "__base__"): {},
        ("proj", "1.0", "pkg2", "foo_extra"): {
            ("proj", "1.0", "pkg3", "__base__"): {"": 1},
        },
        ("proj", "1.0", "pkg3", "__base__"): {},
    }
    activated_extras_1 = {
        ("proj", "1.0", "pkg2", "__base__"): {
            cfg: {
                ("proj", "1.0", "pkg2", "foo_extra"): {"": 1},
            },
        },
    }
    expected_graph_1 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "__base__"): {"": 1},
        },
        ("proj", "1.0", "pkg2", "__base__"): {
            ("proj", "1.0", "pkg3", "__base__"): {"": 1},
        },
        ("proj", "1.0", "pkg3", "__base__"): {},
    }
    result_graph_1 = activate_extras(marker_graph_1, activated_extras_1, cfg)
    asserts.equals(env, expected_graph_1, result_graph_1, "Test Case 1 Failed: Simple extra activation")

    # Test Case 2: No extras activated (dependency on extra exists, but extra not in activated_extras)
    # pkg1[__base__] depends on pkg2[foo_extra]
    # activated_extras is empty
    marker_graph_2 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "foo_extra"): {"": 1},
        },
    }
    activated_extras_2 = {}

    # The expected graph should still have pkg1 depending on pkg2 as base, because normalization happens
    expected_graph_2 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "__base__"): {"": 1},
        },
    }
    result_graph_2 = activate_extras(marker_graph_2, activated_extras_2, cfg)
    asserts.equals(env, expected_graph_2, result_graph_2, "Test Case 2 Failed: No extras activated")

    # Test Case 3: Extra with multiple dependencies and conditional markers
    # pkg1[__base__] depends on pkg2[bar_extra]
    # pkg2[bar_extra] implies dep on pkg3[__base__] (marker: sys_platform=='linux') and pkg4[__base__] (no marker)
    marker_graph_3 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "__base__"): {"": 1},
            ("proj", "1.0", "pkg2", "bar_extra"): {"": 1},
        },
        ("proj", "1.0", "pkg2", "__base__"): {},
        ("proj", "1.0", "pkg2", "bar_extra"): {
            ("proj", "1.0", "pkg3", "__base__"): {"sys_platform=='linux'": 1},
            ("proj", "1.0", "pkg4", "__base__"): {"": 1},
        },
        ("proj", "1.0", "pkg3", "__base__"): {},
        ("proj", "1.0", "pkg4", "__base__"): {},
    }
    activated_extras_3 = {
        ("proj", "1.0", "pkg2", "__base__"): {
            cfg: {
                ("proj", "1.0", "pkg2", "bar_extra"): {"": 1},
            },
        },
    }
    expected_graph_3 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "__base__"): {"": 1},
        },
        ("proj", "1.0", "pkg2", "__base__"): {
            ("proj", "1.0", "pkg3", "__base__"): {"sys_platform=='linux'": 1},
            ("proj", "1.0", "pkg4", "__base__"): {"": 1},
        },
        ("proj", "1.0", "pkg3", "__base__"): {},
        ("proj", "1.0", "pkg4", "__base__"): {},
    }
    result_graph_3 = activate_extras(marker_graph_3, activated_extras_3, cfg)
    asserts.equals(env, expected_graph_3, result_graph_3, "Test Case 3 Failed: Extra with multiple dependencies and conditional markers")

    return unittest.end(env)

extras_activation_test = unittest.make(
    _extras_test_impl,
)

def _collect_sccs_test_impl(ctx):
    env = unittest.begin(ctx)

    # Test case: A simple marker_graph
    marker_graph = {
        ("pkg", "1.0", "dep1", "__base__"): {
            ("pkg", "1.0", "dep2", "__base__"): {"python_version=='3.10'": 1},
        },
        ("pkg", "1.0", "dep2", "__base__"): {
            ("pkg", "1.0", "dep1", "__base__"): {"python_version=='3.11'": 1},
        },
        ("pkg", "1.0", "dep3", "__base__"): {
            ("pkg", "1.0", "dep1", "__base__"): {"": 1},
            ("pkg", "1.0", "dep4", "__base__"): {"": 1},
        },
        ("pkg", "1.0", "dep4", "__base__"): {},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    # 1. Check dep_to_scc
    asserts.equals(env, len(dep_to_scc), 4)  # All 4 dependencies should be mapped
    asserts.equals(env, dep_to_scc[("pkg", "1.0", "dep1", "__base__")], dep_to_scc[("pkg", "1.0", "dep2", "__base__")])
    asserts.true(env, dep_to_scc[("pkg", "1.0", "dep1", "__base__")] != dep_to_scc[("pkg", "1.0", "dep3", "__base__")])
    asserts.true(env, dep_to_scc[("pkg", "1.0", "dep1", "__base__")] != dep_to_scc[("pkg", "1.0", "dep4", "__base__")])
    asserts.true(env, dep_to_scc[("pkg", "1.0", "dep3", "__base__")] != dep_to_scc[("pkg", "1.0", "dep4", "__base__")])

    # 2. Check scc_graph
    asserts.equals(env, len(scc_graph), 3)  # Expect 3 SCCs

    # Find the SCC containing dep1 and dep2
    scc1_id = dep_to_scc[("pkg", "1.0", "dep1", "__base__")]
    asserts.true(env, ("pkg", "1.0", "dep1", "__base__") in scc_graph[scc1_id])
    asserts.true(env, ("pkg", "1.0", "dep2", "__base__") in scc_graph[scc1_id])
    asserts.equals(env, len(scc_graph[scc1_id]), 2)  # Should contain 2 members

    # Check intra-scc markers for scc1
    # dep1 -> dep2
    asserts.true(env, "python_version=='3.10'" in scc_graph[scc1_id][("pkg", "1.0", "dep2", "__base__")])

    # dep2 -> dep1
    asserts.true(env, "python_version=='3.11'" in scc_graph[scc1_id][("pkg", "1.0", "dep1", "__base__")])

    # Find the SCC containing dep3
    scc3_id = dep_to_scc[("pkg", "1.0", "dep3", "__base__")]
    asserts.true(env, ("pkg", "1.0", "dep3", "__base__") in scc_graph[scc3_id])
    asserts.equals(env, len(scc_graph[scc3_id]), 1)

    # Find the SCC containing dep4
    scc4_id = dep_to_scc[("pkg", "1.0", "dep4", "__base__")]
    asserts.true(env, ("pkg", "1.0", "dep4", "__base__") in scc_graph[scc4_id])
    asserts.equals(env, len(scc_graph[scc4_id]), 1)

    # 3. Check scc_deps (external dependencies from SCCs)
    asserts.equals(env, len(scc_deps), 3)  # Should be 3 SCCs with potential external deps

    # SCC containing dep3 should have external deps to dep1 and dep4
    scc3_deps = scc_deps[scc3_id]
    asserts.true(env, ("pkg", "1.0", "dep1", "__base__") in scc3_deps)
    asserts.true(env, ("pkg", "1.0", "dep4", "__base__") in scc3_deps)
    asserts.equals(env, len(scc3_deps), 2)
    asserts.true(env, "" in scc3_deps[("pkg", "1.0", "dep1", "__base__")])
    asserts.true(env, "" in scc3_deps[("pkg", "1.0", "dep4", "__base__")])

    # SCC containing dep1/dep2 should not have external dependencies in this example
    # Note: scc_deps for scc1_id should contain markers from dep1 to dep2 and vice versa, but they are internal.
    # We are checking for *external* deps here.
    asserts.equals(env, len(scc_deps[scc1_id]), 0)

    # SCC containing dep4 should not have external dependencies
    asserts.equals(env, len(scc_deps[scc4_id]), 0)

    return unittest.end(env)

collect_sccs_test = unittest.make(
    _collect_sccs_test_impl,
)

def _collect_sccs_empty_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    marker_graph = {}
    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    asserts.equals(env, len(dep_to_scc), 0, "dep_to_scc should be empty for an empty graph")
    asserts.equals(env, len(scc_graph), 0, "scc_graph should be empty for an empty graph")
    asserts.equals(env, len(scc_deps), 0, "scc_deps should be empty for an empty graph")

    return unittest.end(env)

collect_sccs_empty_graph_test = unittest.make(
    _collect_sccs_empty_graph_test_impl,
)

def _collect_sccs_id_state_test_impl(ctx):
    env = unittest.begin(ctx)

    pkg = ("lock", "cowsay", "6.1", "__base__")
    dep_a = ("lock", "requests", "2.0", "__base__")
    dep_b = ("lock", "urllib3", "1.26", "__base__")

    id_state = {}
    ids_cfg1, _, _ = collect_sccs({pkg: {dep_a: {"": 1}}, dep_a: {}}, id_state)
    ids_cfg2, _, _ = collect_sccs({pkg: {dep_a: {"": 1}}, dep_a: {}}, id_state)

    # A lone base package gets a readable name__version id
    asserts.equals(env, "cowsay__6_1", ids_cfg1[pkg])

    # Identical SCC content across configurations reuses the same id
    asserts.equals(env, ids_cfg1[pkg], ids_cfg2[pkg])

    # Same members but different external deps/markers gets a distinct id
    ids_cfg3, _, _ = collect_sccs({pkg: {dep_b: {"sys_platform == 'linux'": 1}}, dep_b: {}}, id_state)
    asserts.equals(env, "cowsay__6_1__v1", ids_cfg3[pkg])

    # A genuine cycle is named by its member packages
    cycle_ids, _, _ = collect_sccs({pkg: {dep_a: {"": 1}}, dep_a: {pkg: {"": 1}}}, {})
    asserts.equals(env, "cycle__cowsay__requests", cycle_ids[pkg])

    return unittest.end(env)

collect_sccs_id_state_test = unittest.make(
    _collect_sccs_id_state_test_impl,
)

def _collect_sccs_linear_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    marker_graph = {
        ("pkg", "1.0", "A", "__base__"): {("pkg", "1.0", "B", "__base__"): {"": 1}},
        ("pkg", "1.0", "B", "__base__"): {("pkg", "1.0", "C", "__base__"): {"": 1}},
        ("pkg", "1.0", "C", "__base__"): {},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    # All nodes should be in separate SCCs as there are no cycles
    asserts.equals(env, len(dep_to_scc), 3)
    asserts.equals(env, len(scc_graph), 3)
    asserts.equals(env, len(scc_deps), 3)

    scc_a_id = dep_to_scc[("pkg", "1.0", "A", "__base__")]
    scc_b_id = dep_to_scc[("pkg", "1.0", "B", "__base__")]
    scc_c_id = dep_to_scc[("pkg", "1.0", "C", "__base__")]

    asserts.true(env, scc_a_id != scc_b_id)
    asserts.true(env, scc_b_id != scc_c_id)
    asserts.true(env, scc_a_id != scc_c_id)

    asserts.equals(env, len(scc_graph[scc_a_id]), 1)
    asserts.true(env, ("pkg", "1.0", "A", "__base__") in scc_graph[scc_a_id])

    asserts.equals(env, len(scc_graph[scc_b_id]), 1)
    asserts.true(env, ("pkg", "1.0", "B", "__base__") in scc_graph[scc_b_id])

    asserts.equals(env, len(scc_graph[scc_c_id]), 1)
    asserts.true(env, ("pkg", "1.0", "C", "__base__") in scc_graph[scc_c_id])

    # Check external dependencies
    asserts.true(env, ("pkg", "1.0", "B", "__base__") in scc_deps[scc_a_id])
    asserts.equals(env, len(scc_deps[scc_a_id]), 1)

    asserts.true(env, ("pkg", "1.0", "C", "__base__") in scc_deps[scc_b_id])
    asserts.equals(env, len(scc_deps[scc_b_id]), 1)

    asserts.equals(env, len(scc_deps[scc_c_id]), 0)

    return unittest.end(env)

collect_sccs_linear_graph_test = unittest.make(
    _collect_sccs_linear_graph_test_impl,
)

def _collect_sccs_disconnected_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    marker_graph = {
        ("pkg", "1.0", "A", "__base__"): {("pkg", "1.0", "B", "__base__"): {"": 1}},
        ("pkg", "1.0", "B", "__base__"): {},
        ("pkg", "1.0", "X", "__base__"): {("pkg", "1.0", "Y", "__base__"): {"": 1}},
        ("pkg", "1.0", "Y", "__base__"): {},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    asserts.equals(env, len(dep_to_scc), 4)
    asserts.equals(env, len(scc_graph), 4)
    asserts.equals(env, len(scc_deps), 4)

    # All nodes should be in separate SCCs
    scc_a_id = dep_to_scc[("pkg", "1.0", "A", "__base__")]
    scc_b_id = dep_to_scc[("pkg", "1.0", "B", "__base__")]
    scc_x_id = dep_to_scc[("pkg", "1.0", "X", "__base__")]
    scc_y_id = dep_to_scc[("pkg", "1.0", "Y", "__base__")]

    asserts.true(env, scc_a_id != scc_b_id)
    asserts.true(env, scc_x_id != scc_y_id)
    asserts.true(env, scc_a_id != scc_x_id)  # A, B, X, Y should all be distinct SCCs

    # Check external dependencies
    asserts.true(env, ("pkg", "1.0", "B", "__base__") in scc_deps[scc_a_id])
    asserts.equals(env, len(scc_deps[scc_a_id]), 1)
    asserts.equals(env, len(scc_deps[scc_b_id]), 0)

    asserts.true(env, ("pkg", "1.0", "Y", "__base__") in scc_deps[scc_x_id])
    asserts.equals(env, len(scc_deps[scc_x_id]), 1)
    asserts.equals(env, len(scc_deps[scc_y_id]), 0)

    return unittest.end(env)

collect_sccs_disconnected_graph_test = unittest.make(
    _collect_sccs_disconnected_graph_test_impl,
)

def _collect_sccs_single_node_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    marker_graph = {
        ("pkg", "1.0", "A", "__base__"): {},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    asserts.equals(env, len(dep_to_scc), 1)
    asserts.equals(env, len(scc_graph), 1)
    asserts.equals(env, len(scc_deps), 1)

    scc_a_id = dep_to_scc[("pkg", "1.0", "A", "__base__")]
    asserts.true(env, ("pkg", "1.0", "A", "__base__") in scc_graph[scc_a_id])
    asserts.equals(env, len(scc_graph[scc_a_id]), 1)
    asserts.equals(env, len(scc_deps[scc_a_id]), 0)

    return unittest.end(env)

collect_sccs_single_node_graph_test = unittest.make(
    _collect_sccs_single_node_graph_test_impl,
)

def _collect_sccs_self_loop_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    marker_graph = {
        ("pkg", "1.0", "A", "__base__"): {("pkg", "1.0", "A", "__base__"): {"": 1}},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    asserts.equals(env, len(dep_to_scc), 1)
    asserts.equals(env, len(scc_graph), 1)
    asserts.equals(env, len(scc_deps), 1)

    scc_a_id = dep_to_scc[("pkg", "1.0", "A", "__base__")]
    asserts.true(env, ("pkg", "1.0", "A", "__base__") in scc_graph[scc_a_id])
    asserts.equals(env, len(scc_graph[scc_a_id]), 1)
    asserts.true(env, "" in scc_graph[scc_a_id][("pkg", "1.0", "A", "__base__")])
    asserts.equals(env, len(scc_deps[scc_a_id]), 0)

    return unittest.end(env)

collect_sccs_self_loop_graph_test = unittest.make(
    _collect_sccs_self_loop_graph_test_impl,
)

def _collect_sccs_complex_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    marker_graph = {
        ("pkg", "1.0", "A", "__base__"): {("pkg", "1.0", "B", "__base__"): {"": 1}},
        ("pkg", "1.0", "B", "__base__"): {("pkg", "1.0", "C", "__base__"): {"": 1}},
        ("pkg", "1.0", "C", "__base__"): {("pkg", "1.0", "A", "__base__"): {"": 1}},
        ("pkg", "1.0", "D", "__base__"): {("pkg", "1.0", "A", "__base__"): {"": 1}},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    asserts.equals(env, len(dep_to_scc), 4)
    asserts.equals(env, len(scc_graph), 2)  # One SCC for A, B, C; one for D
    asserts.equals(env, len(scc_deps), 2)

    scc_abc_id = dep_to_scc[("pkg", "1.0", "A", "__base__")]
    scc_d_id = dep_to_scc[("pkg", "1.0", "D", "__base__")]

    asserts.true(env, scc_abc_id == dep_to_scc[("pkg", "1.0", "B", "__base__")])
    asserts.true(env, scc_abc_id == dep_to_scc[("pkg", "1.0", "C", "__base__")])
    asserts.true(env, scc_abc_id != scc_d_id)

    asserts.equals(env, len(scc_graph[scc_abc_id]), 3)  # A, B, C are members
    asserts.equals(env, len(scc_graph[scc_d_id]), 1)  # D is a member

    # Check external dependencies for SCC D -> A,B,C
    asserts.true(env, ("pkg", "1.0", "A", "__base__") in scc_deps[scc_d_id])
    asserts.equals(env, len(scc_deps[scc_d_id]), 1)
    asserts.equals(env, len(scc_deps[scc_abc_id]), 0)  # The cycle itself has no external dependencies

    return unittest.end(env)

collect_sccs_complex_cycle_test = unittest.make(
    _collect_sccs_complex_cycle_test_impl,
)

def _collect_build_deps_conditional_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    a, b, c, d, root = [("proj", name, "1", "__base__") for name in ["a", "b", "c", "d", "root"]]
    a2, b2, c2 = [("proj", name, "2", "__base__") for name in ["a", "b", "c"]]
    entry_0 = ("proj", "entry_0", "1", "__base__")
    windows = "sys_platform == 'win32'"
    python = "python_version >= '3.12'"
    marker_graph = {
        a: {b: {windows: 1}},
        b: {c: {"": 1}, d: {python: 1}},
        c: {a: {"": 1}},
        d: {},
        root: {b: {"": 1}},
        # This component's ID collides with A's natural entry-target name.
        a2: {b2: {"": 1}},
        b2: {c2: {"": 1}},
        c2: {entry_0: {"": 1}},
        entry_0: {a2: {"": 1}},
    }
    entries, members, deps = collect_build_deps(marker_graph)

    # Starting at A, neither C nor the outgoing dependency D is reachable
    # when the first edge's Windows condition is false.
    asserts.equals(env, {a: {"": 1}, b: {windows: 1}, c: {windows: 1}}, members[entries[a]])
    asserts.equals(env, {d: {"({}) and ({})".format(python, windows): 1}}, deps[entries[a]])

    # Starting at B bypasses that condition, including when another
    # component enters the cycle through B.
    asserts.equals(env, {a: {"": 1}, b: {"": 1}, c: {"": 1}}, members[entries[b]])
    asserts.equals(env, {d: {python: 1}}, deps[entries[b]])
    asserts.equals(env, {b: {"": 1}}, deps[entries[root]])
    asserts.true(env, entries[a] != entries[b])

    asserts.equals(env, {a2: {"": 1}, b2: {"": 1}, c2: {"": 1}, entry_0: {"": 1}}, members[entries[a2]])
    asserts.true(env, entries[a] != entries[a2])
    return unittest.end(env)

collect_build_deps_conditional_cycle_test = unittest.make(
    _collect_build_deps_conditional_cycle_test_impl,
)

def _exclude_build_dep_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    a = "@a__1//:install"
    b = "@b__1//:install"
    root = "@root__1//:install"
    unrelated = "@unrelated__1//:install"
    scc = "//private/build_deps/sccs:"
    prefix = "//private/build_deps/without/a/sccs:"
    linux = {"sys_platform == 'linux'": 1}
    packages = {
        "a": [{"deps": [a, scc + "cycle__a__b"], "markers": {"": 1}}],
        "b": [{"deps": [b, scc + "cycle__a__b"], "markers": {"": 1}}],
        "root": [{"deps": [root, scc + "root"], "markers": {"": 1}}],
        "unrelated": [{"deps": [unrelated, scc + "unrelated"], "markers": {"": 1}}],
    }

    # A -> B -> A has been condensed into one entry shared by both roots.
    graph = {
        "cycle__a__b": {a: {"": 1}, b: {"": 1}},
        "root": {root: {"": 1}, scc + "cycle__a__b": linux},
        "unrelated": {unrelated: {"": 1}},
    }
    original_packages = {
        name: [{"deps": list(candidate["deps"]), "markers": dict(candidate["markers"])} for candidate in candidates]
        for name, candidates in packages.items()
    }
    original_graph = {
        entry: {dep: dict(markers) for dep, markers in members.items()}
        for entry, members in graph.items()
    }

    changed, cloned = exclude_build_dep(packages, graph, a, prefix)
    asserts.equals(env, {
        "b": [{"deps": [b, prefix + "cycle__a__b"], "markers": {"": 1}}],
        "root": [{"deps": [root, prefix + "root"], "markers": {"": 1}}],
    }, changed)
    asserts.equals(env, {
        "cycle__a__b": {b: {"": 1}},
        "root": {root: {"": 1}, prefix + "cycle__a__b": linux},
    }, cloned)

    # An explicit A requirement and other consumers still use the originals.
    asserts.equals(env, original_packages, packages)
    asserts.equals(env, original_graph, graph)
    return unittest.end(env)

exclude_build_dep_cycle_test = unittest.make(
    _exclude_build_dep_cycle_test_impl,
)

def _exclude_build_dep_conditional_extra_test_impl(ctx):
    env = unittest.begin(ctx)
    a = "@a__1//:install"
    b = "@b__1//:install"
    descendant = "@descendant__1//:install"
    scc = "//private/build_deps/sccs:"
    prefix = "//private/build_deps/without/a/sccs:"
    windows = {"sys_platform == 'win32'": 1}
    python = {"python_version >= '3.12'": 1}
    combined = {"(sys_platform == 'win32') and (python_version >= '3.12')": 1}
    graph = {
        "b": {b: {"": 1}, a: windows, scc + "a_extra": python},
        # Extra entries can contain the same install as the base entry.
        "a_extra": {a: {"": 1}, scc + "descendant": combined},
        "descendant": {descendant: {"": 1}},
    }

    changed, cloned = exclude_build_dep({"b": [{"deps": [b, scc + "b"], "markers": {"": 1}}]}, graph, a, prefix)
    asserts.equals(env, {"b": [{"deps": [b, prefix + "b"], "markers": {"": 1}}]}, changed)
    asserts.equals(env, {
        "b": {b: {"": 1}, prefix + "a_extra": python},
        # Removing A must not remove dependencies reached through A's extra.
        "a_extra": {scc + "descendant": combined},
    }, cloned)
    return unittest.end(env)

exclude_build_dep_conditional_extra_test = unittest.make(
    _exclude_build_dep_conditional_extra_test_impl,
)

def _exclude_build_dep_install_identity_test_impl(ctx):
    env = unittest.begin(ctx)
    a = "@a__1//:install"
    other_version = "@a__2//:install"
    override = "//overrides:a"
    consumer = "@consumer__1//:install"
    scc = "//private/build_deps/sccs:"
    prefix = "//private/build_deps/without/a/sccs:"
    before = {"python_full_version < '3.11'": 1}
    after = {"python_full_version >= '3.11'": 1}
    packages = {
        "a": [
            {"deps": [a, scc + "a"], "markers": before},
            {"deps": [other_version, scc + "other_version"], "markers": after},
        ],
        "override": [{"deps": [override, scc + "override"], "markers": {"": 1}}],
        "consumer": [{"deps": [consumer, scc + "consumer"], "markers": {"": 1}}],
    }
    original_packages = {
        name: [{"deps": list(candidate["deps"]), "markers": dict(candidate["markers"])} for candidate in candidates]
        for name, candidates in packages.items()
    }
    graph = {
        "a": {a: {"": 1}},
        "other_version": {other_version: {"": 1}, a: {"": 1}},
        "override": {override: {"": 1}},
        "consumer": {consumer: {"": 1}, a: {"": 1}, other_version: {"": 1}, override: {"": 1}},
    }

    changed, cloned = exclude_build_dep(packages, graph, a, prefix)

    # Redirecting one fork must retain every candidate and its markers,
    # including the other fork's explicit requirement on the exact self install.
    asserts.equals(env, {
        "a": [
            {"deps": [a, scc + "a"], "markers": before},
            {"deps": [other_version, prefix + "other_version"], "markers": after},
        ],
        "consumer": [{"deps": [consumer, prefix + "consumer"], "markers": {"": 1}}],
    }, changed)
    asserts.equals(env, {other_version: {"": 1}}, cloned["other_version"])
    asserts.equals(env, {consumer: {"": 1}, other_version: {"": 1}, override: {"": 1}}, cloned["consumer"])
    asserts.equals(env, original_packages, packages)
    asserts.equals(env, {other_version: {"": 1}, a: {"": 1}}, graph["other_version"])

    # A direct self requirement alone remains a real requirement, and an absent
    # install does not match a different version or an override with its name.
    asserts.equals(env, ({}, {}), exclude_build_dep({"a": packages["a"][:1]}, graph, a, prefix))
    asserts.equals(env, ({}, {}), exclude_build_dep(packages, graph, "@a__3//:install", prefix))
    return unittest.end(env)

exclude_build_dep_install_identity_test = unittest.make(
    _exclude_build_dep_install_identity_test_impl,
)

def _reachable_build_deps_test_impl(ctx):
    env = unittest.begin(ctx)
    a = "@a__1//:install"
    b = "@b__1//:install"
    b2 = "@b__2//:install"
    c = "@c__1//:install"
    unused = "@unused__1//:install"
    scc = "//private/build_deps/sccs:"
    python = {"python_version >= '3.12'": 1}
    packages = {
        "b": [
            {"deps": [b, scc + "b"], "markers": {"python_full_version < '3.11'": 1}},
            {"deps": [b2, scc + "b2"], "markers": {"python_full_version >= '3.11'": 1}},
        ],
    }
    graph = {
        "a": {a: {"": 1}, scc + "c": python},
        "b": {b: {"": 1}, scc + "a": {"": 1}},
        "b2": {b2: {"": 1}},
        "c": {c: {"": 1}},
        # Another build root can reach A, but B never reaches it or its chain.
        "unused": {unused: {"": 1}, scc + "unused_child": {"": 1}},
        "unused_child": {scc + "a": {"": 1}},
    }

    # Marker evaluation happens later, so both candidate roots must survive.
    expected = {name: graph[name] for name in ["a", "b", "b2", "c"]}
    reachable = reachable_build_deps(packages, graph)
    asserts.equals(env, expected, reachable)
    asserts.equals(env, {}, reachable_build_deps({}, graph))

    # Source repositories exclude from the complete graph before selecting
    # discovered roots. Copies for undiscovered roots must not be emitted.
    changed, copied = exclude_build_dep({
        "b": packages["b"],
        "unused": [{"deps": [unused, scc + "unused"], "markers": {"": 1}}],
    }, graph, a, scc)
    excluded_graph = dict(graph)
    excluded_graph.update(copied)
    asserts.equals(env, {
        "a": {scc + "c": python},
        "b": graph["b"],
        "b2": graph["b2"],
        "c": graph["c"],
    }, reachable_build_deps({"b": changed["b"]}, excluded_graph))
    asserts.equals(env, expected, reachable)
    asserts.equals(env, {a: {"": 1}, scc + "c": python}, graph["a"])
    return unittest.end(env)

reachable_build_deps_test = unittest.make(
    _reachable_build_deps_test_impl,
)

def graph_utils_test_suite():
    unittest.suite(
        "extras_activation_tests",
        extras_activation_test,
    )
    unittest.suite(
        "collect_sccs_tests",
        collect_sccs_test,
        collect_sccs_empty_graph_test,
        collect_sccs_id_state_test,
        collect_sccs_linear_graph_test,
        collect_sccs_disconnected_graph_test,
        collect_sccs_single_node_graph_test,
        collect_sccs_self_loop_graph_test,
        collect_sccs_complex_cycle_test,
        collect_build_deps_conditional_cycle_test,
        exclude_build_dep_cycle_test,
        exclude_build_dep_conditional_extra_test,
        exclude_build_dep_install_identity_test,
        reachable_build_deps_test,
    )
