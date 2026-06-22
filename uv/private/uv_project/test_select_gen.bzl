load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":select_gen.bzl", "build_package_select_arms")

def _ml(expr):
    return "//private/markers:" + expr

def _simple_inactive_marker_test_impl(ctx):
    """Simple marker: inactive on non-Windows hosts falls back to empty."""
    env = unittest.begin(ctx)
    cfg_arms, whl_cfg_arms = build_package_select_arms(
        scc_cfgs = {"scc_ini": {"sys_platform == 'win32'": 1}},
        scc_graph = {},
        package = "iniconfig",
        marker_fn = _ml,
    )
    asserts.equals(env, 2, len(cfg_arms), "want marker arm + default fallback")
    asserts.true(env, "//conditions:default" in cfg_arms)
    asserts.equals(env, "//private/sccs:empty", cfg_arms["//conditions:default"])
    asserts.true(env, "//conditions:default" in whl_cfg_arms)
    asserts.equals(env, ":empty_whl", whl_cfg_arms["//conditions:default"])
    return unittest.end(env)

simple_inactive_marker_test = unittest.make(_simple_inactive_marker_test_impl)

def _compound_and_inactive_marker_test_impl(ctx):
    """Compound AND marker: inactive when any branch is false."""
    env = unittest.begin(ctx)
    cfg_arms, whl_cfg_arms = build_package_select_arms(
        scc_cfgs = {"scc_six": {"sys_platform == 'win32' and python_full_version >= '3.12'": 1}},
        scc_graph = {},
        package = "six",
        marker_fn = _ml,
    )
    asserts.equals(env, 2, len(cfg_arms))
    asserts.true(env, "//conditions:default" in cfg_arms)
    asserts.equals(env, "//private/sccs:empty", cfg_arms["//conditions:default"])
    asserts.equals(env, ":empty_whl", whl_cfg_arms["//conditions:default"])
    return unittest.end(env)

compound_and_inactive_marker_test = unittest.make(_compound_and_inactive_marker_test_impl)

def _compound_or_marker_test_impl(ctx):
    """Compound OR marker: partially matching expression still needs a default arm."""
    env = unittest.begin(ctx)
    cfg_arms, whl_cfg_arms = build_package_select_arms(
        scc_cfgs = {"scc_pkg": {"sys_platform == 'win32' or python_full_version >= '3.12'": 1}},
        scc_graph = {},
        package = "packaging",
        marker_fn = _ml,
    )
    asserts.equals(env, 2, len(cfg_arms), "want OR-marker arm + default fallback")
    asserts.true(
        env,
        "//conditions:default" in cfg_arms,
        "OR marker must have a default arm for the case where no branch matches",
    )
    asserts.equals(env, "//private/sccs:empty", cfg_arms["//conditions:default"])
    asserts.equals(env, ":empty_whl", whl_cfg_arms["//conditions:default"])
    return unittest.end(env)

compound_or_marker_test = unittest.make(_compound_or_marker_test_impl)

def _active_package_test_impl(ctx):
    """Unconditional package: only the default arm is emitted."""
    env = unittest.begin(ctx)
    cfg_arms, whl_cfg_arms = build_package_select_arms(
        scc_cfgs = {"scc_tqdm": {"": 1}},
        scc_graph = {},
        package = "tqdm",
        marker_fn = _ml,
    )
    asserts.equals(env, 1, len(cfg_arms), "active package needs only the unconditional arm")
    asserts.equals(env, "//private/sccs:scc_tqdm", cfg_arms["//conditions:default"])
    return unittest.end(env)

active_package_test = unittest.make(_active_package_test_impl)

def _active_package_whl_arm_test_impl(ctx):
    """Active package with a wheel install resolves the wheel label."""
    env = unittest.begin(ctx)
    cfg_arms, whl_cfg_arms = build_package_select_arms(
        scc_cfgs = {"scc_tqdm": {"": 1}},
        scc_graph = {
            "scc_tqdm": {
                "@whl_install__hub__tqdm__4_68_3//:install": {"": 1},
            },
        },
        package = "tqdm",
        marker_fn = _ml,
    )
    asserts.equals(
        env,
        "@whl_install__hub__tqdm__4_68_3//:whl",
        whl_cfg_arms["//conditions:default"],
    )
    return unittest.end(env)

active_package_whl_arm_test = unittest.make(_active_package_whl_arm_test_impl)

def select_gen_test_suite():
    unittest.suite(
        "select_gen_tests",
        simple_inactive_marker_test,
        compound_and_inactive_marker_test,
        compound_or_marker_test,
        active_package_test,
        active_package_whl_arm_test,
    )
