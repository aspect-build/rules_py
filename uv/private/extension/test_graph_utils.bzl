load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":graph_utils.bzl", "activate_extras", "collect_sccs")

def _extras_test_impl(ctx):
    """Test activate_extras with simple, empty and conditional scenarios."""
    env = unittest.begin(ctx)
    cfg = "default"

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

    marker_graph_2 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "foo_extra"): {"": 1},
        },
    }
    activated_extras_2 = {}
    expected_graph_2 = {
        ("proj", "1.0", "pkg1", "__base__"): {
            ("proj", "1.0", "pkg2", "__base__"): {"": 1},
        },
    }
    result_graph_2 = activate_extras(marker_graph_2, activated_extras_2, cfg)
    asserts.equals(env, expected_graph_2, result_graph_2, "Test Case 2 Failed: No extras activated")

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
    """Test collect_sccs on a graph with a 2-node cycle and an external node."""
    env = unittest.begin(ctx)
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

    asserts.equals(env, len(dep_to_scc), 4)
    asserts.equals(env, dep_to_scc[("pkg", "1.0", "dep1", "__base__")], dep_to_scc[("pkg", "1.0", "dep2", "__base__")])
    asserts.true(env, dep_to_scc[("pkg", "1.0", "dep1", "__base__")] != dep_to_scc[("pkg", "1.0", "dep3", "__base__")])
    asserts.true(env, dep_to_scc[("pkg", "1.0", "dep1", "__base__")] != dep_to_scc[("pkg", "1.0", "dep4", "__base__")])
    asserts.true(env, dep_to_scc[("pkg", "1.0", "dep3", "__base__")] != dep_to_scc[("pkg", "1.0", "dep4", "__base__")])

    asserts.equals(env, len(scc_graph), 3)

    scc1_id = dep_to_scc[("pkg", "1.0", "dep1", "__base__")]
    asserts.true(env, ("pkg", "1.0", "dep1", "__base__") in scc_graph[scc1_id])
    asserts.true(env, ("pkg", "1.0", "dep2", "__base__") in scc_graph[scc1_id])
    asserts.equals(env, len(scc_graph[scc1_id]), 2)

    asserts.true(env, "python_version=='3.8'" in scc_graph[scc1_id][("pkg", "1.0", "dep2", "__base__")])
    asserts.true(env, "python_version=='3.9'" in scc_graph[scc1_id][("pkg", "1.0", "dep1", "__base__")])

    scc3_id = dep_to_scc[("pkg", "1.0", "dep3", "__base__")]
    asserts.true(env, ("pkg", "1.0", "dep3", "__base__") in scc_graph[scc3_id])
    asserts.equals(env, len(scc_graph[scc3_id]), 1)

    scc4_id = dep_to_scc[("pkg", "1.0", "dep4", "__base__")]
    asserts.true(env, ("pkg", "1.0", "dep4", "__base__") in scc_graph[scc4_id])
    asserts.equals(env, len(scc_graph[scc4_id]), 1)

    asserts.equals(env, len(scc_deps), 3)

    scc3_deps = scc_deps[scc3_id]
    asserts.true(env, ("pkg", "1.0", "dep1", "__base__") in scc3_deps)
    asserts.true(env, ("pkg", "1.0", "dep4", "__base__") in scc3_deps)
    asserts.equals(env, len(scc3_deps), 2)
    asserts.true(env, "" in scc3_deps[("pkg", "1.0", "dep1", "__base__")])
    asserts.true(env, "" in scc3_deps[("pkg", "1.0", "dep4", "__base__")])

    asserts.equals(env, len(scc_deps[scc1_id]), 0)
    asserts.equals(env, len(scc_deps[scc4_id]), 0)

    return unittest.end(env)

collect_sccs_test = unittest.make(
    _collect_sccs_test_impl,
)

def _collect_sccs_empty_graph_test_impl(ctx):
    """Test collect_sccs on an empty graph."""
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
    """Test collect_sccs on a linear chain without cycles."""
    env = unittest.begin(ctx)
    marker_graph = {
        ("pkg", "1.0", "A", "__base__"): {("pkg", "1.0", "B", "__base__"): {"": 1}},
        ("pkg", "1.0", "B", "__base__"): {("pkg", "1.0", "C", "__base__"): {"": 1}},
        ("pkg", "1.0", "C", "__base__"): {},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

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
    """Test collect_sccs on two disconnected linear chains."""
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

    scc_a_id = dep_to_scc[("pkg", "1.0", "A", "__base__")]
    scc_b_id = dep_to_scc[("pkg", "1.0", "B", "__base__")]
    scc_x_id = dep_to_scc[("pkg", "1.0", "X", "__base__")]
    scc_y_id = dep_to_scc[("pkg", "1.0", "Y", "__base__")]

    asserts.true(env, scc_a_id != scc_b_id)
    asserts.true(env, scc_x_id != scc_y_id)
    asserts.true(env, scc_a_id != scc_x_id)

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
    """Test collect_sccs on a single isolated node."""
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
    """Test collect_sccs on a node with a self-loop."""
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
    """Test collect_sccs on a 3-node cycle with an external dependency."""
    env = unittest.begin(ctx)
    marker_graph = {
        ("pkg", "1.0", "A", "__base__"): {("pkg", "1.0", "B", "__base__"): {"": 1}},
        ("pkg", "1.0", "B", "__base__"): {("pkg", "1.0", "C", "__base__"): {"": 1}},
        ("pkg", "1.0", "C", "__base__"): {("pkg", "1.0", "A", "__base__"): {"": 1}},
        ("pkg", "1.0", "D", "__base__"): {("pkg", "1.0", "A", "__base__"): {"": 1}},
    }

    dep_to_scc, scc_graph, scc_deps = collect_sccs(marker_graph)

    asserts.equals(env, len(dep_to_scc), 4)
    asserts.equals(env, len(scc_graph), 2)
    asserts.equals(env, len(scc_deps), 2)

    scc_abc_id = dep_to_scc[("pkg", "1.0", "A", "__base__")]
    scc_d_id = dep_to_scc[("pkg", "1.0", "D", "__base__")]

    asserts.true(env, scc_abc_id == dep_to_scc[("pkg", "1.0", "B", "__base__")])
    asserts.true(env, scc_abc_id == dep_to_scc[("pkg", "1.0", "C", "__base__")])
    asserts.true(env, scc_abc_id != scc_d_id)

    asserts.equals(env, len(scc_graph[scc_abc_id]), 3)
    asserts.equals(env, len(scc_graph[scc_d_id]), 1)

    asserts.true(env, ("pkg", "1.0", "A", "__base__") in scc_deps[scc_d_id])
    asserts.equals(env, len(scc_deps[scc_d_id]), 1)
    asserts.equals(env, len(scc_deps[scc_abc_id]), 0)

    return unittest.end(env)

collect_sccs_complex_cycle_test = unittest.make(
    _collect_sccs_complex_cycle_test_impl,
)

def graph_utils_test_suite():
    """Register all graph_utils tests."""
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
