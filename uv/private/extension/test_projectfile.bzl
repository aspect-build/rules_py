load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/markers:pep508_evaluate.bzl", "evaluate")
load(":lockfile.bzl", "collect_locked_requirement_urls")
load(":projectfile.bzl", "collect_activated_extras", "collect_build_dependency_markers", "extract_requirement_marker_pairs", "marker_can_apply")

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

def _extract_requirement_marker_pairs_normalizes_extras_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        'build[SOCKS, Extra__Two, extra...three]; python_version >= "3.9"',
        {"build": ("proj", "build", "1.2.0", "__base__")},
    )
    marker = 'python_version >= "3.9"'
    asserts.equals(env, [
        (("proj", "build", "1.2.0", "__base__"), marker),
        (("proj", "build", "1.2.0", "socks"), marker),
        (("proj", "build", "1.2.0", "extra-two"), marker),
        (("proj", "build", "1.2.0", "extra-three"), marker),
    ], result)
    return unittest.end(env)

extract_requirement_marker_pairs_normalizes_extras_test = unittest.make(
    _extract_requirement_marker_pairs_normalizes_extras_test_impl,
)

def _marker_can_apply_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, marker_can_apply("python_version < '3.0'", ">=3.11"))
    asserts.false(
        env,
        marker_can_apply("sys_platform == 'linux' and python_version < '3.0'", ">=3.11"),
    )
    asserts.false(env, marker_can_apply("python_version >= '3.11'", "==3.10.19"))
    asserts.true(env, marker_can_apply("python_version == '3.12'", ">=3.11"))
    asserts.true(
        env,
        marker_can_apply("sys_platform == 'linux' and python_version >= '3.11'", ">=3.11"),
    )
    asserts.true(env, marker_can_apply("sys_platform == 'linux'", ">=3.11"))
    return unittest.end(env)

marker_can_apply_test = unittest.make(_marker_can_apply_test_impl)

def _collect_build_dependency_markers_test_impl(ctx):
    env = unittest.begin(ctx)
    build = ("lock", "build", "1.0.0", "__base__")
    build_extra = ("lock", "build", "1.0.0", "feature")
    packaging_21 = ("lock", "packaging", "21.3", "__base__")
    packaging_24 = ("lock", "packaging", "24.0", "__base__")
    colorama = ("lock", "colorama", "0.4.6", "__base__")
    pysocks = ("lock", "pysocks", "1.7.1", "__base__")
    root_marker = "sys_platform == 'linux'"
    version_marker = "python_version >= '3.11'"
    extra_marker = "platform_machine == 'aarch64'"
    transitive_marker = "platform_python_implementation == 'CPython'"

    marked_deps = collect_build_dependency_markers(
        {
            build: {packaging_24: {version_marker: 1}},
            build_extra: {pysocks: {extra_marker: 1}},
            packaging_21: {},
            packaging_24: {colorama: {transitive_marker: 1}},
            colorama: {},
            pysocks: {},
        },
        [(build, root_marker), (build_extra, root_marker)],
    )

    packaging_marker = "({}) and ({})".format(root_marker, version_marker)
    asserts.equals(env, {root_marker: 1}, marked_deps.get(build, {}))
    asserts.equals(env, {packaging_marker: 1}, marked_deps.get(packaging_24, {}))
    asserts.equals(
        env,
        {"({}) and ({})".format(packaging_marker, transitive_marker): 1},
        marked_deps.get(colorama, {}),
    )
    asserts.equals(
        env,
        {"({}) and ({})".format(root_marker, extra_marker): 1},
        marked_deps.get(pysocks, {}),
    )
    asserts.false(env, packaging_21 in marked_deps)
    return unittest.end(env)

collect_build_dependency_markers_test = unittest.make(
    _collect_build_dependency_markers_test_impl,
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

    hashed = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "build @ https://example.invalid/build-1.3.0-py3-none-any.whl#sha256=4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274",
        {},
        versions,
        locked_urls = locked_urls,
    )
    asserts.equals(env, [(("proj", "build", "1.3.0", "__base__"), "")], hashed)

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

def _collect_locked_requirement_urls_local_sources_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        (
            "archive-build",
            "path",
            "../artifacts/archive-build-1.0.0.whl",
            "file:///workspace/artifacts/archive-build-1.0.0.whl",
        ),
        (
            "directory-build",
            "directory",
            "packages/../packages/directory-build",
            "file:///workspace/project/packages/directory-build",
        ),
        (
            "editable-build",
            "editable",
            "packages/editable-build",
            "file:///workspace/project/packages/editable-build",
        ),
        (
            "absolute-build",
            "path",
            "/opt/build/absolute-build-4.0.0.whl",
            "file:///opt/build/absolute-build-4.0.0.whl",
        ),
        (
            "double-slash-build",
            "path",
            "//opt/build/double-slash-build.whl",
            "file:///opt/build/double-slash-build.whl",
        ),
        (
            "file-build",
            "path",
            "file:///opt/build/file-build-5.0.0.whl",
            "file:///opt/build/file-build-5.0.0.whl",
        ),
        (
            "spaced-build",
            "directory",
            "packages/local build",
            "file:///workspace/project/packages/local%20build",
        ),
        (
            "reserved-build",
            "directory",
            "packages/uv #?%\"<>`{}\\path",
            "file:///workspace/project/packages/uv%20%23%3F%25%22%3C%3E%60%7B%7D%5Cpath",
        ),
        (
            "safe-build",
            "directory",
            "packages/[keep]@name;version:",
            "file:///workspace/project/packages/[keep]@name;version:",
        ),
        (
            "unicode-build",
            "directory",
            "packages/ümlaut/雪😀",
            "file:///workspace/project/packages/%C3%BCmlaut/%E9%9B%AA%F0%9F%98%80",
        ),
        (
            "control-build",
            "directory",
            "packages/line\nbreak\tend",
            "file:///workspace/project/packages/line%0Abreak%09end",
        ),
        (
            "windows-build",
            "path",
            "C:\\build tools\\windows-build-11.0.0.whl",
            "file:///C:/build%20tools/windows-build-11.0.0.whl",
        ),
        (
            "unc-build",
            "directory",
            "\\\\fileserver\\build tools\\unc#build",
            "file://fileserver/build%20tools/unc%23build",
        ),
    ]
    packages = []
    expected_urls = {}
    for i, (name, source_kind, local_path, expected_url) in enumerate(cases):
        version = "{}.0.0".format(i + 1)
        normalized_name = name.replace("-", "_")
        packages.append({
            "name": name,
            "version": version,
            "source": {source_kind: local_path},
        })
        expected_urls[(normalized_name, expected_url)] = (
            "proj",
            normalized_name,
            version,
            "__base__",
        )

    asserts.equals(
        env,
        expected_urls,
        collect_locked_requirement_urls("proj", {"package": packages}, "/workspace/project"),
    )
    return unittest.end(env)

collect_locked_requirement_urls_local_sources_test = unittest.make(
    _collect_locked_requirement_urls_local_sources_test_impl,
)

def _extract_requirement_marker_pairs_local_reference_test_impl(ctx):
    env = unittest.begin(ctx)
    locked_urls = collect_locked_requirement_urls(
        "proj",
        {
            "package": [
                {
                    "name": "directory-build",
                    "version": "2.0.0",
                    "source": {"directory": "packages/directory-build"},
                },
                {
                    "name": "safe-build",
                    "version": "8.0.0",
                    "source": {"directory": "packages/[keep]@name;version:"},
                },
            ],
        },
        "/workspace/project",
    )

    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "directory-build[feature] @ file:///workspace/project/packages/directory-build; sys_platform == 'linux'",
        {},
        {"directory_build": {"2.0.0": 1}},
        locked_urls = locked_urls,
    )
    asserts.equals(env, [
        (("proj", "directory_build", "2.0.0", "__base__"), "sys_platform == 'linux'"),
        (("proj", "directory_build", "2.0.0", "feature"), "sys_platform == 'linux'"),
    ], result)

    safe_url = "file:///workspace/project/packages/[keep]@name;version:"
    safe = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "safe-build @ " + safe_url,
        {},
        {"safe_build": {"8.0.0": 1}},
        locked_urls = locked_urls,
    )
    asserts.equals(env, [
        (("proj", "safe_build", "8.0.0", "__base__"), ""),
    ], safe)

    marked_safe = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "safe-build[feature] @ " + safe_url + " ; sys_platform == 'linux'",
        {},
        {"safe_build": {"8.0.0": 1}},
        locked_urls = locked_urls,
    )
    asserts.equals(env, [
        (("proj", "safe_build", "8.0.0", "__base__"), "sys_platform == 'linux'"),
        (("proj", "safe_build", "8.0.0", "feature"), "sys_platform == 'linux'"),
    ], marked_safe)

    missing = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "proj",
        "directory-build @ file:///workspace/project/packages/other-build",
        {},
        {"directory_build": {"2.0.0": 1}},
        fail_if_missing = False,
        locked_urls = locked_urls,
    )
    asserts.equals(env, [], missing)
    return unittest.end(env)

extract_requirement_marker_pairs_local_reference_test = unittest.make(
    _extract_requirement_marker_pairs_local_reference_test_impl,
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

def _collect_build_dependency_markers_nested_extras_test_impl(ctx):
    env = unittest.begin(ctx)
    build = ("lock", "build", "1.0.0", "__base__")
    build_extra = ("lock", "build", "1.0.0", "first")
    nested = ("lock", "nested", "1.0.0", "__base__")
    nested_extra = ("lock", "nested", "1.0.0", "second")
    base_leaf = ("lock", "base_leaf", "1.0.0", "__base__")
    nested_leaf = ("lock", "nested_leaf", "1.0.0", "__base__")
    extra_leaf = ("lock", "extra_leaf", "1.0.0", "__base__")
    root_marker = "sys_platform == 'linux'"
    base_marker = "python_version >= '3.11'"
    nested_marker = "platform_machine == 'aarch64'"
    nested_base_marker = "os_name == 'posix'"
    extra_marker = "platform_python_implementation == 'CPython'"

    marked_deps = collect_build_dependency_markers(
        {
            build: {base_leaf: {base_marker: 1}},
            build_extra: {nested_extra: {nested_marker: 1}},
            nested: {nested_leaf: {nested_base_marker: 1}},
            nested_extra: {extra_leaf: {extra_marker: 1}},
            base_leaf: {},
            nested_leaf: {},
            extra_leaf: {},
        },
        [(build_extra, root_marker)],
    )

    nested_path = "({}) and ({})".format(root_marker, nested_marker)
    asserts.equals(env, {root_marker: 1}, marked_deps.get(build, {}))
    asserts.equals(
        env,
        {"({}) and ({})".format(root_marker, base_marker): 1},
        marked_deps.get(base_leaf, {}),
    )
    asserts.equals(env, {nested_path: 1}, marked_deps.get(nested, {}))
    asserts.equals(
        env,
        {"({}) and ({})".format(nested_path, nested_base_marker): 1},
        marked_deps.get(nested_leaf, {}),
    )
    asserts.equals(
        env,
        {"({}) and ({})".format(nested_path, extra_marker): 1},
        marked_deps.get(extra_leaf, {}),
    )
    return unittest.end(env)

collect_build_dependency_markers_nested_extras_test = unittest.make(
    _collect_build_dependency_markers_nested_extras_test_impl,
)

def _collect_build_dependency_markers_multiple_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    first = ("lock", "first", "1.0.0", "__base__")
    second = ("lock", "second", "1.0.0", "__base__")
    shared = ("lock", "shared", "1.0.0", "__base__")
    leaf = ("lock", "leaf", "1.0.0", "__base__")
    first_root = "sys_platform == 'linux'"
    second_root = "sys_platform == 'darwin'"
    first_edge = "python_version >= '3.11'"
    second_edge = "os_name == 'posix'"
    leaf_edge = "platform_python_implementation == 'CPython'"

    marked_deps = collect_build_dependency_markers(
        {
            first: {shared: {first_edge: 1}},
            second: {shared: {second_edge: 1}},
            shared: {leaf: {leaf_edge: 1}},
            leaf: {},
        },
        [(first, first_root), (second, second_root)],
    )

    shared_markers = {
        "({}) and ({})".format(first_root, first_edge): 1,
        "({}) and ({})".format(second_root, second_edge): 1,
    }
    asserts.equals(env, shared_markers, marked_deps.get(shared, {}))
    asserts.equals(
        env,
        {
            "({}) and ({})".format(marker, leaf_edge): 1
            for marker in shared_markers
        },
        marked_deps.get(leaf, {}),
    )
    return unittest.end(env)

collect_build_dependency_markers_multiple_paths_test = unittest.make(
    _collect_build_dependency_markers_multiple_paths_test_impl,
)

def _collect_build_dependency_markers_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    first = ("lock", "first", "1.0.0", "__base__")
    second = ("lock", "second", "1.0.0", "__base__")
    leaf = ("lock", "leaf", "1.0.0", "__base__")
    root_marker = "sys_platform != 'win32'"
    edge_marker = "python_version >= '3.11'"
    leaf_marker = "platform_python_implementation == 'CPython'"

    marked_deps = collect_build_dependency_markers(
        {
            first: {second: {edge_marker: 1}},
            second: {
                first: {"os_name == 'posix'": 1},
                leaf: {leaf_marker: 1},
            },
            leaf: {},
        },
        [(first, root_marker)],
    )

    second_marker = "({}) and ({})".format(root_marker, edge_marker)
    asserts.equals(env, {root_marker: 1}, marked_deps.get(first, {}))
    asserts.equals(env, {second_marker: 1}, marked_deps.get(second, {}))
    asserts.equals(
        env,
        {"({}) and ({})".format(second_marker, leaf_marker): 1},
        marked_deps.get(leaf, {}),
    )
    return unittest.end(env)

collect_build_dependency_markers_cycle_test = unittest.make(
    _collect_build_dependency_markers_cycle_test_impl,
)

def _collect_build_dependency_markers_conflict_extras_test_impl(ctx):
    env = unittest.begin(ctx)
    build = ("lock", "build", "1.0.0", "__base__")
    selected = ("lock", "packaging", "24.0", "__base__")
    unselected = ("lock", "packaging", "21.3", "__base__")
    windows_only = ("lock", "colorama", "0.4.6", "__base__")
    selected_marker = "extra == 'group-a' or extra != 'group-b'"
    unselected_marker = "extra == 'group-b'"
    platform_marker = "os_name == 'nt' or (extra == 'group-a' and extra == 'group-b')"

    marked_deps = collect_build_dependency_markers(
        {
            build: {
                selected: {selected_marker: 1},
                unselected: {unselected_marker: 1},
                windows_only: {platform_marker: 1},
            },
            selected: {},
            unselected: {},
            windows_only: {},
        },
        [(build, "")],
    )

    asserts.equals(env, {"": 1}, marked_deps.get(selected, {}))
    asserts.false(env, unselected in marked_deps)
    markers = marked_deps.get(windows_only, {})
    asserts.equals(env, 1, len(markers))
    for marker in markers:
        asserts.true(env, evaluate(marker, env = {"os_name": "nt"}))
        asserts.false(env, evaluate(marker, env = {"os_name": "posix"}))
    return unittest.end(env)

collect_build_dependency_markers_conflict_extras_test = unittest.make(
    _collect_build_dependency_markers_conflict_extras_test_impl,
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
        extract_requirement_marker_pairs_normalizes_extras_test,
        marker_can_apply_test,
        collect_build_dependency_markers_test,
        collect_build_dependency_markers_nested_extras_test,
        collect_build_dependency_markers_multiple_paths_test,
        collect_build_dependency_markers_cycle_test,
        collect_build_dependency_markers_conflict_extras_test,
        extract_requirement_marker_pairs_direct_reference_test,
        collect_locked_requirement_urls_local_sources_test,
        extract_requirement_marker_pairs_local_reference_test,
        extract_requirement_marker_pairs_preferred_overrides_version_map_test,
        extract_requirement_marker_pairs_preferred_overrides_multi_version_test,
        collect_activated_extras_transitive_remap_test,
    )
