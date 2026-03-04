load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":graph_utils.bzl", "activate_extras", "collect_sccs")

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
            ("pkg", "1.0", "dep2", "__base__"): {"python_version=='3.8'": 1},
        },
        ("pkg", "1.0", "dep2", "__base__"): {
            ("pkg", "1.0", "dep1", "__base__"): {"python_version=='3.9'": 1},
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
    asserts.true(env, "python_version=='3.8'" in scc_graph[scc1_id][("pkg", "1.0", "dep2", "__base__")])

    # dep2 -> dep1
    asserts.true(env, "python_version=='3.9'" in scc_graph[scc1_id][("pkg", "1.0", "dep1", "__base__")])

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

def graph_utils_test_suite():
    unittest.suite(
        "extras_activation_tests",
        extras_activation_test,
    )
    unittest.suite(
        "collect_sccs_tests",
        collect_sccs_test,
        collect_sccs_empty_graph_test,
        collect_sccs_linear_graph_test,
        collect_sccs_disconnected_graph_test,
        collect_sccs_single_node_graph_test,
        collect_sccs_self_loop_graph_test,
        collect_sccs_complex_cycle_test,
    )
