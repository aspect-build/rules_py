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

def _extract_requirement_marker_pairs_direct_reference_test_impl(ctx):
    env = unittest.begin(ctx)
    versions = {"build": {"1.3.0": 1, "2.0.0": 1}}
    locked_urls = {
        ("build", "https://example.invalid/build-1.3.0-py3-none-any.whl"): ("proj", "build", "1.3.0", "__base__"),
    }
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        'build[extra] @ https://example.invalid/build-1.3.0-py3-none-any.whl ; python_version >= "3.9"',
        {},
        versions,
        locked_urls = locked_urls,
    )
    asserts.equals(env, 2, len(result))
    asserts.equals(env, (("proj", "build", "1.3.0", "__base__"), 'python_version >= "3.9"'), result[0])
    asserts.equals(env, (("proj", "build", "1.3.0", "extra"), 'python_version >= "3.9"'), result[1])

    missing = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "build@https://example.invalid/build-2.0.0-py3-none-any.whl",
        {},
        versions,
        fail_if_missing = False,
        locked_urls = locked_urls,
    )
    asserts.equals(env, [], missing)
    return unittest.end(env)

extract_requirement_marker_pairs_direct_reference_test = unittest.make(
    _extract_requirement_marker_pairs_direct_reference_test_impl,
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

def _collect_activated_extras_build_extra_test_impl(ctx):
    env = unittest.begin(ctx)
    urllib3 = ("lock", "urllib3", "2.6.3", "__base__")
    urllib3_brotli = ("lock", "urllib3", "2.6.3", "brotli")
    brotli = ("lock", "brotli", "1.2.0", "__base__")
    graph = {
        urllib3: {},
        urllib3_brotli: {brotli: {"platform_python_implementation == 'CPython'": 1}},
        brotli: {},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        {
            "project": {"name": "test_project"},
            "dependency-groups": {"runtime": ["urllib3"]},
        },
        {},
        {"urllib3": urllib3, "brotli": brotli},
        graph,
        {"urllib3": {"2.6.3": 1}, "brotli": {"1.2.0": 1}},
        {urllib3_brotli: {"sys_platform != 'win32'": 1}},
    )

    asserts.equals(env, {"sys_platform != 'win32'": 1}, activated_extras[urllib3]["runtime"][urllib3_brotli])
    asserts.equals(env, {"platform_python_implementation == 'CPython'": 1}, activated_extras[brotli]["runtime"][brotli])
    return unittest.end(env)

collect_activated_extras_build_extra_test = unittest.make(
    _collect_activated_extras_build_extra_test_impl,
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

def projectfile_test_suite():
    unittest.suite(
        "extract_requirement_marker_pairs_tests",
        extract_requirement_marker_pairs_multi_version_no_specifier_test,
        extract_requirement_marker_pairs_multi_version_with_specifier_test,
        extract_requirement_marker_pairs_single_version_via_map_test,
        extract_requirement_marker_pairs_with_extras_test,
        extract_requirement_marker_pairs_direct_reference_test,
        extract_requirement_marker_pairs_preferred_overrides_version_map_test,
        extract_requirement_marker_pairs_preferred_overrides_multi_version_test,
        collect_activated_extras_build_extra_test,
        collect_activated_extras_transitive_remap_test,
    )
