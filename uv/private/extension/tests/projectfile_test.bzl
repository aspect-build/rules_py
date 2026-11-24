load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/extension:projectfile.bzl", "collect_activated_extras", "extract_requirement_marker_pairs")

# Markers as `uv lock` writes them for a project `conflict-repro` whose groups
# `cpu` and `cuda` conflict, each with its own torch index.
_CPU = "group-14-conflict-repro-cpu"
_CUDA = "group-14-conflict-repro-cuda"
_TORCH_DARWIN = "(sys_platform == 'darwin' and extra == '{cpu}') or (extra == '{cpu}' and extra == '{cuda}')".format(cpu = _CPU, cuda = _CUDA)
_TORCH_CPU = "(sys_platform != 'darwin' and extra == '{cpu}') or (extra == '{cpu}' and extra == '{cuda}')".format(cpu = _CPU, cuda = _CUDA)
_TORCH_PYPI = "(extra != '{cpu}' and extra != '{cuda}') or (extra == '{cpu}' and extra == '{cuda}')".format(cpu = _CPU, cuda = _CUDA)
_TORCH_CU129 = "extra == '{cuda}'".format(cuda = _CUDA)


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
        'build[extra1,extra2] >= 1.0; python_version >= "3.10"',
        {},
        {"build": {"1.0.0": 1, "1.1.0": 1}},
    )
    asserts.equals(env, 3, len(result))
    asserts.equals(env, (("proj", "build", "1.1.0", "__base__"), 'python_version >= "3.10"'), result[0])
    asserts.equals(env, (("proj", "build", "1.1.0", "extra1"), 'python_version >= "3.10"'), result[1])
    asserts.equals(env, (("proj", "build", "1.1.0", "extra2"), 'python_version >= "3.10"'), result[2])
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

def _extract_requirement_marker_pairs_preferred_satisfying_wildcard_test_impl(ctx):
    env = unittest.begin(ctx)
    preferred = {"foo": ("proj", "foo", "1.2", "__base__")}
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "foo==1.*",
        {},
        {"foo": {"1.2": 1, "1.9": 1}},
        preferred,
    )
    asserts.equals(env, [(("proj", "foo", "1.2", "__base__"), "")], result)
    return unittest.end(env)

extract_requirement_marker_pairs_preferred_satisfying_wildcard_test = unittest.make(
    _extract_requirement_marker_pairs_preferred_satisfying_wildcard_test_impl,
)

def _extract_requirement_marker_pairs_unsatisfied_preferred_matches_lock_test_impl(ctx):
    env = unittest.begin(ctx)
    preferred = {"foo": ("proj", "foo", "2.0", "__base__")}
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        'foo<2; sys_platform != "darwin"',
        {"foo": ("proj", "foo", "2.0", "__base__")},
        {"foo": {"1.5": 1, "2.0": 1}},
        preferred,
    )
    asserts.equals(env, [(("proj", "foo", "1.5", "__base__"), 'sys_platform != "darwin"')], result)
    return unittest.end(env)

extract_requirement_marker_pairs_unsatisfied_preferred_matches_lock_test = unittest.make(
    _extract_requirement_marker_pairs_unsatisfied_preferred_matches_lock_test_impl,
)

def _extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "foo>=2",
        {"foo": ("proj", "foo", "1.9", "__base__")},
        {"foo": {"1.9": 1}},
    )
    asserts.equals(env, [(("proj", "foo", "1.9", "__base__"), "")], result)
    return unittest.end(env)

extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test = unittest.make(
    _extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test_impl,
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

def _collect_activated_extras_platform_split_transitive_markers_test_impl(ctx):
    env = unittest.begin(ctx)
    darwin = 'sys_platform == "darwin"'
    not_darwin = 'sys_platform != "darwin"'

    # The transitive edges are unconditional because their platform markers are
    # redundant with the direct requirements. The traversal must carry those
    # direct markers forward rather than making both transitive versions global.
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "default": [
                "platform-parent==1.0; {}".format(darwin),
                "platform-parent==2.0; {}".format(not_darwin),
            ],
        },
    }
    lock_data = {
        "package": [
            {
                "name": "test_project",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "default": [
                        {"name": "platform-parent", "version": "1.0"},
                        {"name": "platform-parent", "version": "2.0"},
                    ],
                },
            },
        ],
    }
    parent_1 = ("lock", "platform_parent", "1.0", "__base__")
    parent_2 = ("lock", "platform_parent", "2.0", "__base__")
    transitive_1 = ("lock", "transitive_dep", "1.0", "__base__")
    transitive_2 = ("lock", "transitive_dep", "2.0", "__base__")
    graph = {
        parent_1: {transitive_1: {"": 1}},
        parent_2: {transitive_2: {"": 1}},
        transitive_1: {},
        transitive_2: {},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        lock_data,
        {},
        graph,
        {
            "platform_parent": {"1.0": 1, "2.0": 1},
            "transitive_dep": {"1.0": 1, "2.0": 1},
        },
    )

    asserts.equals(env, {darwin: 1}, activated_extras[transitive_1]["default"][transitive_1])
    asserts.equals(env, {not_darwin: 1}, activated_extras[transitive_2]["default"][transitive_2])
    return unittest.end(env)

collect_activated_extras_platform_split_transitive_markers_test = unittest.make(
    _collect_activated_extras_platform_split_transitive_markers_test_impl,
)

def _collect_activated_extras_conditional_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    root_marker = 'sys_platform == "linux"'
    edge_marker = 'python_version < "3.13"'
    cycle_marker = 'platform_python_implementation == "CPython"'
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "default": ["package-a==1.0; {}".format(root_marker)],
        },
    }
    package_a = ("lock", "package_a", "1.0", "__base__")
    package_b = ("lock", "package_b", "1.0", "__base__")
    graph = {
        package_a: {package_b: {edge_marker: 1}},
        package_b: {package_a: {cycle_marker: 1}},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        {},
        {},
        graph,
        {
            "package_a": {"1.0": 1},
            "package_b": {"1.0": 1},
        },
    )

    asserts.equals(env, {root_marker: 1}, activated_extras[package_a]["default"][package_a])
    asserts.equals(
        env,
        {"({}) and ({})".format(edge_marker, root_marker): 1},
        activated_extras[package_b]["default"][package_b],
    )
    return unittest.end(env)

collect_activated_extras_conditional_cycle_test = unittest.make(
    _collect_activated_extras_conditional_cycle_test_impl,
)

def _collect_activated_extras_clause_rendering_collision_test_impl(ctx):
    env = unittest.begin(ctx)
    a = 'python_version < "3.13"'
    b = 'sys_platform == "linux"'
    rendered = "({}) and ({})".format(a, b)
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "default": [
                "split-parent==1.0; {}".format(a),
                "paren-parent==1.0",
                "plain-parent==1.0",
            ],
        },
    }
    split_parent = ("lock", "split_parent", "1.0", "__base__")
    paren_parent = ("lock", "paren_parent", "1.0", "__base__")
    plain_parent = ("lock", "plain_parent", "1.0", "__base__")
    leaf = ("lock", "leaf", "1.0", "__base__")
    graph = {
        split_parent: {leaf: {b: 1}},
        paren_parent: {leaf: {rendered: 1}},
        plain_parent: {leaf: {"": 1}},
        leaf: {},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        {},
        {},
        graph,
        {
            "split_parent": {"1.0": 1},
            "paren_parent": {"1.0": 1},
            "plain_parent": {"1.0": 1},
            "leaf": {"1.0": 1},
        },
    )

    asserts.equals(env, {"": 1}, activated_extras[leaf]["default"][leaf])
    return unittest.end(env)

collect_activated_extras_clause_rendering_collision_test = unittest.make(
    _collect_activated_extras_clause_rendering_collision_test_impl,
)

def _conflict_torch_fixture():
    """Two conflicting groups, each with its own torch index, reaching torch
    both directly and through a workspace member `lib`, as `uv lock` writes
    it."""
    project_data = {
        "project": {"name": "conflict-repro"},
        "dependency-groups": {
            "cpu": ["lib", "torch==2.9.1"],
            "cuda": ["lib", "torch==2.9.1"],
        },
    }
    lock_data = {
        "conflicts": [[
            {"package": "conflict-repro", "group": "cpu"},
            {"package": "conflict-repro", "group": "cuda"},
        ]],
        "package": [
            {
                "name": "conflict-repro",
                "version": "0.0.0",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "cpu": [
                        {"name": "lib", "version": "0.1.0"},
                        {"name": "torch", "version": "2.9.1", "marker": _TORCH_DARWIN},
                        {"name": "torch", "version": "2.9.1+cpu", "marker": _TORCH_CPU},
                    ],
                    "cuda": [
                        {"name": "lib", "version": "0.1.0"},
                        {"name": "torch", "version": "2.9.1+cu129"},
                    ],
                },
            },
        ],
    }
    lib = ("lock", "lib", "0.1.0", "__base__")
    torch_darwin = ("lock", "torch", "2.9.1", "__base__")
    torch_cpu = ("lock", "torch", "2.9.1+cpu", "__base__")
    torch_cu129 = ("lock", "torch", "2.9.1+cu129", "__base__")
    graph = {
        lib: {
            torch_darwin: {_TORCH_DARWIN: 1, _TORCH_PYPI: 1},
            torch_cpu: {_TORCH_CPU: 1},
            torch_cu129: {_TORCH_CU129: 1},
        },
        torch_darwin: {},
        torch_cpu: {},
        torch_cu129: {},
    }
    return struct(
        project_data = project_data,
        lock_data = lock_data,
        graph = graph,
        default_versions = {"lib": lib},
        package_versions = {
            "lib": {"0.1.0": 1},
            "torch": {"2.9.1": 1, "2.9.1+cpu": 1, "2.9.1+cu129": 1},
        },
        torch_darwin = torch_darwin,
        torch_cpu = torch_cpu,
        torch_cu129 = torch_cu129,
    )

def _collect_activated_extras_conflict_groups_test_impl(ctx):
    env = unittest.begin(ctx)
    fx = _conflict_torch_fixture()

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        fx.project_data,
        fx.lock_data,
        fx.default_versions,
        fx.graph,
        fx.package_versions,
    )

    def markers(dep, group):
        return activated_extras.get(dep, {}).get(group, {}).get(dep)

    # Each group reaches only the torch of its own index: the routing terms
    # of the other group's entries are decided false, never left for build
    # time.
    asserts.equals(env, None, markers(fx.torch_cu129, "cpu"))

    asserts.equals(env, {"": 1}, markers(fx.torch_cu129, "cuda"))
    asserts.equals(env, None, markers(fx.torch_darwin, "cuda"))
    asserts.equals(env, None, markers(fx.torch_cpu, "cuda"))

    return unittest.end(env)

collect_activated_extras_conflict_groups_test = unittest.make(
    _collect_activated_extras_conflict_groups_test_impl,
)

def _collect_activated_extras_normalized_group_name_test_impl(ctx):
    env = unittest.begin(ctx)

    # uv.lock spells groups normalized; a pyproject group `Dev_GPU` is locked
    # as `dev-gpu` and must still find its locked versions.
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {"Dev_GPU": ["six"]},
    }
    lock_data = {
        "package": [
            {
                "name": "test_project",
                "version": "0.0.0",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "dev-gpu": [
                        {"name": "six", "version": "1.16.0"},
                    ],
                },
            },
        ],
    }
    six_116 = ("lock", "six", "1.16.0", "__base__")
    six_117 = ("lock", "six", "1.17.0", "__base__")
    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        lock_data,
        {},
        {six_116: {}, six_117: {}},
        {"six": {"1.16.0": 1, "1.17.0": 1}},
    )
    # The group's locked version wins over the highest one in the lockfile.
    asserts.equals(env, {"": 1}, activated_extras[six_116]["Dev_GPU"][six_116])
    asserts.false(env, six_117 in activated_extras)

    return unittest.end(env)

collect_activated_extras_normalized_group_name_test = unittest.make(
    _collect_activated_extras_normalized_group_name_test_impl,
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
        extract_requirement_marker_pairs_preferred_satisfying_wildcard_test,
        extract_requirement_marker_pairs_unsatisfied_preferred_matches_lock_test,
        extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test,
        collect_activated_extras_transitive_remap_test,
        collect_activated_extras_platform_split_transitive_markers_test,
        collect_activated_extras_conditional_cycle_test,
        collect_activated_extras_clause_rendering_collision_test,
        collect_activated_extras_conflict_groups_test,
        collect_activated_extras_normalized_group_name_test,
    )
