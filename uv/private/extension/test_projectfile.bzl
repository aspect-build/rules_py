load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":projectfile.bzl", "collect_activated_extras", "extract_requirement_marker_pairs")

def _extract_requirement_marker_pairs_multi_version_no_specifier_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "build",
        {},
        {"build": {"1.3.0": 1, "1.4.0": 1}},
    )
    asserts.equals(env, 1, len(result))
    dep, marker = result[0]
    asserts.equals(env, ("proj", "build", "1.4.0", "__base__"), dep)
    asserts.equals(env, "", marker)
    return unittest.end(env)

extract_requirement_marker_pairs_multi_version_no_specifier_test = unittest.make(
    _extract_requirement_marker_pairs_multi_version_no_specifier_test_impl,
)

def _extract_requirement_marker_pairs_multi_version_with_specifier_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "build>=1.3.0,<1.4.0",
        {},
        {"build": {"1.2.0": 1, "1.3.0": 1, "1.4.0": 1}},
    )
    asserts.equals(env, 1, len(result))
    dep, marker = result[0]
    asserts.equals(env, ("proj", "build", "1.3.0", "__base__"), dep)
    asserts.equals(env, "", marker)
    return unittest.end(env)

extract_requirement_marker_pairs_multi_version_with_specifier_test = unittest.make(
    _extract_requirement_marker_pairs_multi_version_with_specifier_test_impl,
)

def _extract_requirement_marker_pairs_single_version_via_map_test_impl(ctx):
    env = unittest.begin(ctx)
    version_map = {"build": ("proj", "build", "1.2.0", "__base__")}
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "build",
        version_map,
        {"build": {"1.2.0": 1, "1.3.0": 1}},
    )
    asserts.equals(env, 1, len(result))
    dep, marker = result[0]
    asserts.equals(env, ("proj", "build", "1.2.0", "__base__"), dep)
    asserts.equals(env, "", marker)
    return unittest.end(env)

extract_requirement_marker_pairs_single_version_via_map_test = unittest.make(
    _extract_requirement_marker_pairs_single_version_via_map_test_impl,
)

def _extract_requirement_marker_pairs_with_extras_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        'build[extra1,extra2] >= 1.0; python_version >= "3.9"',
        {},
        {"build": {"1.0.0": 1, "1.1.0": 1}},
    )
    asserts.equals(env, 3, len(result))
    asserts.equals(env, (("proj", "build", "1.1.0", "__base__"), 'python_version >= "3.9"'), result[0])
    asserts.equals(env, (("proj", "build", "1.1.0", "extra1"), 'python_version >= "3.9"'), result[1])
    asserts.equals(env, (("proj", "build", "1.1.0", "extra2"), 'python_version >= "3.9"'), result[2])
    return unittest.end(env)

extract_requirement_marker_pairs_with_extras_test = unittest.make(
    _extract_requirement_marker_pairs_with_extras_test_impl,
)

def _extract_requirement_marker_pairs_preferred_overrides_version_map_test_impl(ctx):
    env = unittest.begin(ctx)
    version_map = {"build": ("proj", "build", "1.2.0", "__base__")}
    preferred = {"build": ("proj", "build", "1.3.0", "__base__")}
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "build",
        version_map,
        {"build": {"1.2.0": 1, "1.3.0": 1}},
        preferred,
    )
    asserts.equals(env, 1, len(result))
    dep, _marker = result[0]
    asserts.equals(env, ("proj", "build", "1.3.0", "__base__"), dep)
    return unittest.end(env)

extract_requirement_marker_pairs_preferred_overrides_version_map_test = unittest.make(
    _extract_requirement_marker_pairs_preferred_overrides_version_map_test_impl,
)

def _extract_requirement_marker_pairs_preferred_overrides_multi_version_test_impl(ctx):
    env = unittest.begin(ctx)
    preferred = {"build": ("proj", "build", "1.3.0", "__base__")}
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "build",
        {},
        {"build": {"1.3.0": 1, "1.4.0": 1}},
        preferred,
    )
    asserts.equals(env, 1, len(result))
    dep, _marker = result[0]
    asserts.equals(env, ("proj", "build", "1.3.0", "__base__"), dep)
    return unittest.end(env)

extract_requirement_marker_pairs_preferred_overrides_multi_version_test = unittest.make(
    _extract_requirement_marker_pairs_preferred_overrides_multi_version_test_impl,
)

def _collect_activated_extras_transitive_remap_test_impl(ctx):
    env = unittest.begin(ctx)
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "group_a": ["build", "packaging==24.0"],
            "group_b": ["build", "packaging==21.3"],
        },
    }
    lock_data = {
        "manifest": {"members": ["test_project"]},
        "package": [
            {
                "name": "test_project",
                "version": "0.0.0",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "group_a": [
                        {"name": "build", "version": "1.4.3"},
                        {"name": "packaging", "version": "24.0"},
                    ],
                    "group_b": [
                        {"name": "build", "version": "1.3.0"},
                        {"name": "packaging", "version": "21.3"},
                    ],
                },
            },
        ],
    }
    graph = {
        ("lock", "build", "1.4.3", "__base__"): {
            ("lock", "packaging", "24.0", "__base__"): {"": 1},
        },
        ("lock", "build", "1.3.0", "__base__"): {
            ("lock", "packaging", "21.3", "__base__"): {"": 1},
        },
        ("lock", "packaging", "24.0", "__base__"): {},
        ("lock", "packaging", "21.3", "__base__"): {},
    }
    default_versions = {}
    package_versions = {
        "build": {"1.3.0": 1, "1.4.3": 1},
        "packaging": {"21.3": 1, "24.0": 1},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        lock_data,
        default_versions,
        graph,
        package_versions,
    )

    build_143 = ("lock", "build", "1.4.3", "__base__")
    build_130 = ("lock", "build", "1.3.0", "__base__")
    base_24 = ("lock", "packaging", "24.0", "__base__")
    base_21 = ("lock", "packaging", "21.3", "__base__")

    asserts.true(env, build_143 in activated_extras)
    asserts.true(env, "group_a" in activated_extras[build_143])
    asserts.false(env, "group_a" in activated_extras.get(build_130, {}))
    asserts.true(env, base_24 in activated_extras)
    asserts.true(env, "group_a" in activated_extras[base_24])
    asserts.false(env, "group_a" in activated_extras.get(base_21, {}))

    # group_b should use build==1.3.0 and packaging==21.3
    asserts.true(env, build_130 in activated_extras)
    asserts.true(env, "group_b" in activated_extras[build_130])
    asserts.false(env, "group_b" in activated_extras.get(build_143, {}))
    asserts.true(env, base_21 in activated_extras)
    asserts.true(env, "group_b" in activated_extras[base_21])
    asserts.false(env, "group_b" in activated_extras.get(base_24, {}))

    return unittest.end(env)

collect_activated_extras_transitive_remap_test = unittest.make(
    _collect_activated_extras_transitive_remap_test_impl,
)

def _collect_activated_extras_group_multi_version_test_impl(ctx):
    env = unittest.begin(ctx)
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "group_m": [
                "retrying==1.3.4",
                "six==1.16.0; sys_platform == 'linux'",
                "six==1.17.0; sys_platform != 'linux'",
            ],
        },
    }
    lock_data = {
        "manifest": {"members": ["test_project"]},
        "package": [
            {
                "name": "test_project",
                "version": "0.0.0",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "group_m": [
                        {"name": "retrying"},
                        {"name": "six", "version": "1.16.0", "marker": "sys_platform == 'linux'"},
                        {"name": "six", "version": "1.17.0", "marker": "sys_platform != 'linux'"},
                    ],
                },
            },
        ],
    }
    six_116 = ("lock", "six", "1.16.0", "__base__")
    six_117 = ("lock", "six", "1.17.0", "__base__")
    retrying = ("lock", "retrying", "1.3.4", "__base__")
    graph = {
        retrying: {
            six_116: {"sys_platform == 'linux'": 1},
            six_117: {"sys_platform != 'linux'": 1},
        },
        six_116: {},
        six_117: {},
    }
    default_versions = {"retrying": retrying}
    package_versions = {
        "retrying": {"1.3.4": 1},
        "six": {"1.16.0": 1, "1.17.0": 1},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        lock_data,
        default_versions,
        graph,
        package_versions,
    )

    asserts.true(env, retrying in activated_extras)
    asserts.true(env, "group_m" in activated_extras[retrying])

    # Both locked versions must be activated for the group, each gated by
    # the conjunction of the requirement/edge marker and its lockfile marker.
    asserts.true(env, six_116 in activated_extras)
    asserts.true(env, "group_m" in activated_extras[six_116])
    asserts.true(env, six_117 in activated_extras)
    asserts.true(env, "group_m" in activated_extras[six_117])

    markers_116 = activated_extras[six_116]["group_m"][six_116]
    markers_117 = activated_extras[six_117]["group_m"][six_117]

    # Each version is gated by exactly its satisfiable lockfile marker.
    # Unconditional activation, the sibling's marker, and cross-candidate
    # contradictions must all be absent: a contradictory conjunction has the
    # same canonical form for both versions, which repository generation
    # rejects as one marker gating two packages.
    asserts.equals(env, {"sys_platform == 'linux'": 1}, markers_116)
    asserts.equals(env, {"sys_platform != 'linux'": 1}, markers_117)

    return unittest.end(env)

collect_activated_extras_group_multi_version_test = unittest.make(
    _collect_activated_extras_group_multi_version_test_impl,
)

def _collect_activated_extras_group_marker_fallback_test_impl(ctx):
    env = unittest.begin(ctx)
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "group_f": [
                "retrying==1.3.4",
                "six==1.16.0; sys_platform == 'linux'",
            ],
        },
    }
    lock_data = {
        "manifest": {"members": ["test_project"]},
        "package": [
            {
                "name": "test_project",
                "version": "0.0.0",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "group_f": [
                        {"name": "retrying"},
                        {"name": "six", "version": "1.16.0", "marker": "sys_platform == 'linux'"},
                    ],
                },
            },
        ],
    }
    six_116 = ("lock", "six", "1.16.0", "__base__")
    six_117 = ("lock", "six", "1.17.0", "__base__")
    retrying = ("lock", "retrying", "1.3.4", "__base__")
    graph = {
        retrying: {
            six_117: {"sys_platform != 'linux'": 1},
        },
        six_116: {},
        six_117: {},
    }
    default_versions = {"retrying": retrying}
    package_versions = {
        "retrying": {"1.3.4": 1},
        "six": {"1.16.0": 1, "1.17.0": 1},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        lock_data,
        default_versions,
        graph,
        package_versions,
    )

    # The single lockfile candidate's marker must be preserved, not promoted
    # to an unconditional preference.
    markers_116 = activated_extras[six_116]["group_f"][six_116]
    asserts.false(env, "" in markers_116)
    asserts.true(env, "sys_platform == 'linux'" in markers_116)

    # The transitive edge resolves a version outside the group's candidate
    # set; it must survive the fan-out so non-linux environments still wire
    # a version instead of remapping to the linux-only candidate.
    asserts.true(env, six_117 in activated_extras)
    asserts.true(env, "group_f" in activated_extras[six_117])
    markers_117 = activated_extras[six_117]["group_f"][six_117]
    asserts.true(env, "sys_platform != 'linux'" in markers_117)
    asserts.false(env, "" in markers_117)

    return unittest.end(env)

collect_activated_extras_group_marker_fallback_test = unittest.make(
    _collect_activated_extras_group_marker_fallback_test_impl,
)

def _collect_activated_extras_transitive_condition_propagation_test_impl(ctx):
    env = unittest.begin(ctx)
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "group_p": ["foo"],
        },
    }
    lock_data = {
        "manifest": {"members": ["test_project"]},
        "package": [
            {
                "name": "test_project",
                "version": "0.0.0",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "group_p": [
                        {"name": "foo", "version": "1.0", "marker": "sys_platform == 'linux'"},
                        {"name": "foo", "version": "2.0", "marker": "sys_platform != 'linux'"},
                    ],
                },
            },
        ],
    }
    foo_1 = ("lock", "foo", "1.0", "__base__")
    foo_2 = ("lock", "foo", "2.0", "__base__")
    bar_1 = ("lock", "bar", "1.0", "__base__")
    bar_2 = ("lock", "bar", "2.0", "__base__")

    # Each foo version depends *unconditionally* on a different bar version;
    # bar is transitive-only, so the group has no candidates for it.
    graph = {
        foo_1: {bar_1: {"": 1}},
        foo_2: {bar_2: {"": 1}},
        bar_1: {},
        bar_2: {},
    }
    default_versions = {}
    package_versions = {
        "bar": {"1.0": 1, "2.0": 1},
        "foo": {"1.0": 1, "2.0": 1},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        lock_data,
        default_versions,
        graph,
        package_versions,
    )

    # Each bar version must inherit the platform gate of the foo candidate
    # that pulls it in. If the walk drops path conditions, both bar versions
    # become unconditional and repository generation reports two default
    # package states for the same group.
    markers_bar_1 = activated_extras[bar_1]["group_p"][bar_1]
    markers_bar_2 = activated_extras[bar_2]["group_p"][bar_2]

    asserts.false(env, "" in markers_bar_1)
    asserts.false(env, "" in markers_bar_2)

    asserts.true(env, "sys_platform == 'linux'" in markers_bar_1)
    asserts.true(env, "sys_platform != 'linux'" in markers_bar_2)

    asserts.false(env, "sys_platform != 'linux'" in markers_bar_1)
    asserts.false(env, "sys_platform == 'linux'" in markers_bar_2)

    return unittest.end(env)

collect_activated_extras_transitive_condition_propagation_test = unittest.make(
    _collect_activated_extras_transitive_condition_propagation_test_impl,
)

def projectfile_test_suite():
    unittest.suite(
        "extract_requirement_marker_pairs_tests",
        extract_requirement_marker_pairs_multi_version_no_specifier_test,
        extract_requirement_marker_pairs_multi_version_with_specifier_test,
        extract_requirement_marker_pairs_single_version_via_map_test,
        extract_requirement_marker_pairs_with_extras_test,
        extract_requirement_marker_pairs_preferred_overrides_version_map_test,
        extract_requirement_marker_pairs_preferred_overrides_multi_version_test,
        collect_activated_extras_transitive_remap_test,
        collect_activated_extras_group_multi_version_test,
        collect_activated_extras_group_marker_fallback_test,
        collect_activated_extras_transitive_condition_propagation_test,
    )
