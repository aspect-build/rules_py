"""Unit + analysis tests for whl_install wheel selection and metadata."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//py/private:providers.bzl", "PyWheelsInfo")
load(":repository.bzl", "compatible_python_tags", "parse_console_script", "parse_console_scripts", "parse_record_path", "select_key", "site_packages_segments", "sort_select_arms", "source_specificity", "wheel_layout_from_record")
load(":rule.bzl", "whl_install")

def _whl_sorting_test_impl(ctx):
    env = unittest.begin(ctx)

    a = ("cp314", "musllinux_1_2_s390x", "cp314")
    at = ("cp314", "musllinux_1_2_s390x", "cp314t")

    # Ensure that the freethreaded wheel scores lowest
    asserts.true(env, select_key(at) > select_key(a))

    # Ensure that the sorted arms put the freethreaded wheel first
    asserts.equals(
        env,
        [
            (at, None),
            (a, None),
        ],
        sort_select_arms({
            a: None,
            at: None,
        }).items(),
    )

    return unittest.end(env)

whl_sorting_test = unittest.make(
    _whl_sorting_test_impl,
)

def _abi3_compatibility_test_impl(ctx):
    env = unittest.begin(ctx)

    # cp<X>-abi3 expands forward across supported CPython minors.
    asserts.equals(
        env,
        ["cp3{}".format(m) for m in range(10, 21)],
        compatible_python_tags("cp310", "abi3"),
    )

    # Non-abi3 wheels are not expanded.
    asserts.equals(
        env,
        ["cp310"],
        compatible_python_tags("cp310", "cp310"),
    )

    # abi3 forward-compat is CPython-only; py-prefixed tags pass through.
    asserts.equals(
        env,
        ["py3"],
        compatible_python_tags("py3", "abi3"),
    )

    return unittest.end(env)

abi3_compatibility_test = unittest.make(
    _abi3_compatibility_test_impl,
)

def _source_specificity_test_impl(ctx):
    env = unittest.begin(ctx)

    # Higher minor = more specific. Disambiguates two abi3 wheels that
    # expand into the same compatible_python_tag (cp38-abi3 and cp311-abi3
    # both cover cp312+; cp311 wins).
    asserts.true(env, source_specificity("cp311") > source_specificity("cp38"))
    asserts.true(env, source_specificity("cp312") > source_specificity("cp311"))

    # Non-cp tags don't participate in abi3 expansion; score them lowest
    # so they never beat a cp source on conflict.
    asserts.true(env, source_specificity("cp38") > source_specificity("py3"))

    return unittest.end(env)

source_specificity_test = unittest.make(
    _source_specificity_test_impl,
)

def _record_path_test_impl(ctx):
    env = unittest.begin(ctx)

    # Unquoted: the common case.
    asserts.equals(env, "plain.py", parse_record_path("plain.py,sha256=abc,1"))

    # Quoted because the path contains a comma (the reason a real wheel
    # quotes a RECORD path at all).
    asserts.equals(
        env,
        "pkg/data/sample,1.csv",
        parse_record_path("\"pkg/data/sample,1.csv\",sha256=abc,1"),
    )

    # Quoted with both an embedded comma and a doubled-quote escape ("" -> ").
    asserts.equals(
        env,
        "package/a,b\"c.py",
        parse_record_path("\"package/a,b\"\"c.py\",,"),
    )

    # Empty first field (blank line, or a leading comma) yields no path; the
    # caller skips falsy paths.
    asserts.equals(env, "", parse_record_path(""))
    asserts.equals(env, "", parse_record_path(",sha256=abc,1"))

    # Byte-faithful to csv.reader on malformed-but-parseable rows (these don't
    # occur in valid RECORD files, but we match the reader rather than guess):
    #
    #   text after a closing quote concatenates literally,
    asserts.equals(env, "abcdef", parse_record_path("\"abc\"def,1"))

    #   with quotes in that trailing text staying literal,
    asserts.equals(env, "abcdef\"ghi\"", parse_record_path("\"abc\"def\"ghi\",1"))

    #   a `"` that does not open the field is a literal character,
    asserts.equals(env, "a\"b\"c", parse_record_path("a\"b\"c,1"))

    #   and an unterminated quote consumes the rest of the row.
    asserts.equals(env, "unterminated,1", parse_record_path("\"unterminated,1"))

    return unittest.end(env)

record_path_test = unittest.make(_record_path_test_impl)

def _console_scripts_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [
        "Mixed-Case=package:Commands.main",
        "duplicate=package:new",
    ], parse_console_scripts("""
[console_scripts]
Mixed-Case = package:Commands.main [legacy-extra]
duplicate = package:old
# The last declaration wins when strict parsing is disabled.
duplicate = package:new
malformed = package
[gui_scripts]
ignored = package:main
"""))
    return unittest.end(env)

console_scripts_test = unittest.make(_console_scripts_test_impl)

def _site_packages_segments_test_impl(ctx):
    env = unittest.begin(ctx)
    data = "Legacy.Name-1.0.data"
    asserts.equals(env, ["pkg", "module.py"], site_packages_segments(
        data + "/purelib/pkg/module.py",
        data,
    ))
    asserts.equals(env, ["pkg", "native.so"], site_packages_segments(
        data + "/platlib/pkg/native.so",
        data,
    ))
    asserts.equals(env, [], site_packages_segments(
        data + "/scripts/tool",
        data,
    ))
    asserts.equals(env, [], site_packages_segments(
        data + "/headers/pkg/header.h",
        data,
    ))
    asserts.equals(env, [], site_packages_segments(
        data + "/data/config.json",
        data,
    ))
    asserts.equals(env, ["custom", "pkg", "module.py"], site_packages_segments(
        data + "/custom/pkg/module.py",
        data,
    ))
    return unittest.end(env)

site_packages_segments_test = unittest.make(_site_packages_segments_test_impl)

def _console_script_test_impl(ctx):
    env = unittest.begin(ctx)

    # Plain entry: normalised to "name=module:func".
    asserts.equals(
        env,
        ("foo", "foo=pkg.mod:main"),
        parse_console_script("foo = pkg.mod:main"),
    )

    # Legacy extras (`[...]`) are parsed and dropped from the function.
    asserts.equals(
        env,
        ("foo", "foo=pkg.mod:main"),
        parse_console_script("foo = pkg.mod:main [extra1,extra2]"),
    )

    # Surrounding whitespace on every component is stripped, including a
    # space-separated extras suffix.
    asserts.equals(
        env,
        ("foo", "foo=pkg.mod:main"),
        parse_console_script("  foo  =  pkg.mod : main  [ a , b ]  "),
    )

    # Missing function (bare module, or trailing colon) is rejected — a
    # console script must name a callable.
    asserts.equals(env, None, parse_console_script("foo = pkg.mod"))
    asserts.equals(env, None, parse_console_script("foo = pkg.mod:"))
    asserts.equals(env, None, parse_console_script("foo = pkg.mod: [extra]"))

    # Missing module or name is rejected.
    asserts.equals(env, None, parse_console_script("foo = :main"))
    asserts.equals(env, None, parse_console_script(" = pkg.mod:main"))

    # No `=` at all is not an assignment.
    asserts.equals(env, None, parse_console_script("pkg.mod:main"))

    return unittest.end(env)

console_script_test = unittest.make(_console_script_test_impl)

def _wheel_layout_metadata_test_impl(ctx):
    env = unittest.begin(ctx)
    layout = wheel_layout_from_record(
        "\n".join([
            # Repository classification deliberately covers possible target
            # loaders and static tooling, not only the repository host's
            # active FileFinder suffixes.
            "top_source/__init__.py,,",
            "top_pyi/__init__.pyi,,",
            "top_pyw/__init__.pyw,,",
            "top_pyc/__init__.pyc,,",
            "top_case/__INIT__.Py,,",
            "top_native/__init__.cpython-311-x86_64-linux-gnu.so,,",
            "namespace/framework_plugin/__INIT__.cpython-314-ios-arm64.FWORK,,",
            "namespace/pyi_plugin/__init__.pyi,,",
            "namespace/pyw_plugin/__init__.pyw,,",
            "namespace/pyc_plugin/__init__.pyc,,",
            "namespace/native_plugin/__init__.abi3.so,,",
            "namespace/windows_plugin/__init__.cp311-win_amd64.pyd,,",
            "namespace/plain/module.py,,",
            "demo-1.0.dist-info/RECORD,,",
        ]),
        "demo-1.0.data",
    )

    asserts.equals(env, [
        "demo-1.0.dist-info",
        "namespace",
        "top_case",
        "top_native",
        "top_pyc",
        "top_pyi",
        "top_pyw",
        "top_source",
    ], layout.top_levels)
    asserts.equals(env, layout.top_levels, layout.directory_top_levels)
    asserts.equals(env, ["namespace"], layout.namespace_top_levels)
    asserts.equals(env, [
        "namespace/framework_plugin",
        "namespace/native_plugin",
        "namespace/plain/module.py",
        "namespace/pyc_plugin",
        "namespace/pyi_plugin",
        "namespace/pyw_plugin",
        "namespace/windows_plugin",
    ], layout.namespace_entries)
    asserts.equals(env, ["namespace/plain"], layout.namespace_dirs)
    asserts.equals(env, [
        "namespace/framework_plugin",
        "namespace/native_plugin",
        "namespace/pyc_plugin",
        "namespace/pyi_plugin",
        "namespace/pyw_plugin",
        "namespace/windows_plugin",
    ], layout.regular_roots)
    return unittest.end(env)

wheel_layout_metadata_test = unittest.make(_wheel_layout_metadata_test_impl)

# --- whl_install metadata selection ---------------------------------------
#
# Regression: the package surface advertised via PyWheelsInfo (top-levels,
# console scripts) must be limited to the wheel selected for the active
# configuration. The metadata attrs carry entries for EVERY platform wheel,
# keyed by wheel file basename; the rule must use only the entry matching
# the wheel `src` resolved to. Historically the repo rule unioned the
# metadata across all platform wheels, leaking e.g. the macOS C-extension
# suffix (a dangling site-packages symlink) and macOS-only console scripts
# into Linux builds.

_LINUX_WHL = "demo-1.0.0-cp311-cp311-manylinux_2_17_x86_64.whl"
_MACOS_WHL = "demo-1.0.0-cp311-cp311-macosx_11_0_arm64.whl"

# A selected wheel basename absent from every metadata map exercises the
# complete-wheel fallback.
_METADATA_MISS_WHL = "demo-1.0.0-py3-none-any.whl"

_TOP_LEVELS = {
    _LINUX_WHL: [
        "_demo_backend.cpython-311-x86_64-linux-gnu.so",
        "demo",
        "demo-1.0.0.dist-info",
    ],
    _MACOS_WHL: [
        "_demo_backend.cpython-311-darwin.so",
        "demo",
        "demo-1.0.0.dist-info",
        "demo_ns",
    ],
}

_DIRECTORY_TOP_LEVELS = {
    _LINUX_WHL: ["demo", "demo-1.0.0.dist-info"],
    _MACOS_WHL: ["demo", "demo-1.0.0.dist-info", "demo_ns"],
}

_NAMESPACE_TOP_LEVELS = {
    _MACOS_WHL: ["demo_ns"],
}

_NAMESPACE_ENTRIES = {
    _MACOS_WHL: ["demo_ns/plugin"],
}

_NAMESPACE_DIRS = {
    _MACOS_WHL: ["demo_ns/shared"],
}

_REGULAR_ROOTS = {
    _MACOS_WHL: ["demo_ns/plugin"],
}

_CONSOLE_SCRIPTS = {
    _LINUX_WHL: [],
    _MACOS_WHL: [
        "demo-mac=demo.cli:mac_main",
        "demo=demo.cli:main",
    ],
}

_BUILT_WHEEL_TOP_LEVELS = [
    "demo",
    "demo-1.0.0.dist-info",
]

_BUILT_WHEEL_CONSOLE_SCRIPTS = ["demo=demo.cli:main"]

def _metadata_selection_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    wheels = target[PyWheelsInfo].wheels.to_list()
    asserts.equals(env, 1, len(wheels), "expected exactly one wheel struct in PyWheelsInfo")

    wheel = wheels[0]
    asserts.equals(env, target.label, wheel.install_tree.owner)
    asserts.equals(env, tuple(ctx.attr.expected_top_levels), wheel.top_levels)
    asserts.equals(env, tuple(ctx.attr.expected_directory_top_levels), wheel.directory_top_levels)
    asserts.equals(env, ctx.attr.expected_layout_known, wheel.layout_known)
    asserts.equals(env, tuple(ctx.attr.expected_namespace_top_levels), wheel.namespace_top_levels)
    asserts.equals(env, tuple(ctx.attr.expected_namespace_entries), wheel.namespace_entries)
    asserts.equals(env, tuple(ctx.attr.expected_namespace_dirs), wheel.namespace_dirs)
    asserts.equals(env, tuple(ctx.attr.expected_regular_roots), wheel.regular_roots)
    asserts.equals(env, tuple(ctx.attr.expected_console_scripts), wheel.console_scripts)
    asserts.equals(env, ctx.attr.expected_scripts_known, wheel.scripts_known)

    # Explicit leak checks: surface belonging to the OTHER (inactive)
    # platform wheel must not appear for this configuration's wheel.
    for leaked in ctx.attr.leaked_top_levels:
        asserts.false(
            env,
            leaked in wheel.top_levels,
            "top-level '{}' from an inactive platform wheel leaked into the selected wheel's surface".format(leaked),
        )
    for leaked in ctx.attr.leaked_console_scripts:
        asserts.false(
            env,
            leaked in wheel.console_scripts,
            "console script '{}' from an inactive platform wheel leaked into the selected wheel's surface".format(leaked),
        )

    actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "WhlInstall"
    ]
    asserts.equals(env, 1, len(actions))
    metadata_args = []
    if len(actions) == 1:
        metadata_args = [
            actions[0].argv[index + 1]
            for index in range(len(actions[0].argv) - 1)
            if actions[0].argv[index] == "--expected-metadata"
        ]
    asserts.equals(env, 1 if ctx.attr.expected_layout_known or ctx.attr.expected_scripts_known else 0, len(metadata_args))
    if len(metadata_args) == 1:
        expected_metadata = json.decode(metadata_args[0])
        asserts.equals(env, ctx.attr.expected_layout_known, "top_levels" in expected_metadata)
        asserts.equals(env, ctx.attr.expected_scripts_known, "console_scripts" in expected_metadata)
        if ctx.attr.expect_empty_scripts_validation:
            asserts.equals(env, [], expected_metadata.get("console_scripts"))

    return analysistest.end(env)

_metadata_selection_test = analysistest.make(
    _metadata_selection_test_impl,
    attrs = {
        "expected_top_levels": attr.string_list(),
        "expected_directory_top_levels": attr.string_list(),
        "expected_layout_known": attr.bool(default = True),
        "expected_namespace_top_levels": attr.string_list(),
        "expected_namespace_entries": attr.string_list(),
        "expected_namespace_dirs": attr.string_list(),
        "expected_regular_roots": attr.string_list(),
        "expected_console_scripts": attr.string_list(),
        "expected_scripts_known": attr.bool(default = True),
        "expect_empty_scripts_validation": attr.bool(),
        "leaked_top_levels": attr.string_list(),
        "leaked_console_scripts": attr.string_list(),
    },
)

def _metadata_miss_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    asserts.false(
        env,
        PyWheelsInfo in target,
        "a wheel with unknown layout and scripts must retain no-provider fallback",
    )
    actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "WhlInstall"
    ]
    asserts.equals(env, 1, len(actions))
    if len(actions) == 1:
        asserts.false(env, "--expected-metadata" in actions[0].argv)
    return analysistest.end(env)

_metadata_miss_test = analysistest.make(_metadata_miss_test_impl)

def metadata_selection_test_suite(name):
    """Fixtures + analysis tests for per-configuration metadata selection.

    Args:
        name: prefix for the generated test targets.
    """

    for basename in [_LINUX_WHL, _MACOS_WHL, _METADATA_MISS_WHL]:
        # The wheel is never unpacked at analysis time; an empty stub file
        # with the right basename is enough to drive the metadata lookup.
        write_file(
            name = "__stub_" + basename,
            out = basename,
            content = [""],
            tags = ["manual"],
        )

    for fixture_name, src in [
        ("__metadata_linux_fixture", _LINUX_WHL),
        ("__metadata_macos_fixture", _MACOS_WHL),
        ("__metadata_miss_fixture", _METADATA_MISS_WHL),
    ]:
        whl_install(
            name = fixture_name,
            src = src,
            top_levels = _TOP_LEVELS,
            directory_top_levels = _DIRECTORY_TOP_LEVELS,
            namespace_top_levels = _NAMESPACE_TOP_LEVELS,
            namespace_entries = _NAMESPACE_ENTRIES,
            namespace_dirs = _NAMESPACE_DIRS,
            regular_roots = _REGULAR_ROOTS,
            console_scripts = _CONSOLE_SCRIPTS,
            tags = ["manual"],
        )

    native.alias(
        name = "__metadata_declared_sbuild_selected",
        actual = "//uv/private/pep517_whl:__built_wheel_metadata_fixture",
        tags = ["manual"],
    )

    whl_install(
        name = "__metadata_declared_sbuild_fixture",
        src = ":__metadata_declared_sbuild_selected",
        tags = ["manual"],
    )

    native.alias(
        name = "__metadata_console_script_only_sbuild_selected",
        actual = "//uv/private/pep517_whl:__console_script_only_metadata_fixture",
        tags = ["manual"],
    )

    whl_install(
        name = "__metadata_console_script_only_sbuild_fixture",
        src = ":__metadata_console_script_only_sbuild_selected",
        tags = ["manual"],
    )

    native.alias(
        name = "__metadata_declared_sbuild_no_scripts_selected",
        actual = "//uv/private/pep517_whl:__top_level_only_metadata_fixture",
        tags = ["manual"],
    )

    whl_install(
        name = "__metadata_declared_sbuild_no_scripts_fixture",
        src = ":__metadata_declared_sbuild_no_scripts_selected",
        tags = ["manual"],
    )

    native.alias(
        name = "__metadata_unknown_sbuild_selected",
        actual = "//uv/private/pep517_whl:__unknown_built_wheel_metadata_fixture",
        tags = ["manual"],
    )

    whl_install(
        name = "__metadata_unknown_sbuild_fixture",
        src = ":__metadata_unknown_sbuild_selected",
        tags = ["manual"],
    )

    whl_install(
        name = "__metadata_compile_pyc_fixture",
        src = _LINUX_WHL,
        compile_pyc = True,
        top_levels = {_LINUX_WHL: ["demo.py"]},
        tags = ["manual"],
    )

    write_file(
        name = "__metadata_empty_scripts_patch",
        out = "metadata-empty-scripts.patch",
        content = [""],
        tags = ["manual"],
    )

    whl_install(
        name = "__metadata_empty_scripts_patched_fixture",
        src = _MACOS_WHL,
        console_scripts = {_MACOS_WHL: []},
        directory_top_levels = _DIRECTORY_TOP_LEVELS,
        namespace_top_levels = _NAMESPACE_TOP_LEVELS,
        namespace_entries = _NAMESPACE_ENTRIES,
        namespace_dirs = _NAMESPACE_DIRS,
        regular_roots = _REGULAR_ROOTS,
        patches = [":__metadata_empty_scripts_patch"],
        tags = ["manual"],
        top_levels = _TOP_LEVELS,
    )

    _metadata_selection_test(
        name = name + "_linux_test",
        target_under_test = ":__metadata_linux_fixture",
        expected_top_levels = _TOP_LEVELS[_LINUX_WHL],
        expected_directory_top_levels = _DIRECTORY_TOP_LEVELS[_LINUX_WHL],
        expected_console_scripts = _CONSOLE_SCRIPTS[_LINUX_WHL],
        leaked_top_levels = [
            "_demo_backend.cpython-311-darwin.so",
            "demo_ns",
        ],
        leaked_console_scripts = ["demo-mac=demo.cli:mac_main"],
    )

    _metadata_selection_test(
        name = name + "_macos_test",
        target_under_test = ":__metadata_macos_fixture",
        expected_top_levels = _TOP_LEVELS[_MACOS_WHL],
        expected_directory_top_levels = _DIRECTORY_TOP_LEVELS[_MACOS_WHL],
        expected_namespace_dirs = _NAMESPACE_DIRS[_MACOS_WHL],
        expected_namespace_entries = _NAMESPACE_ENTRIES[_MACOS_WHL],
        expected_namespace_top_levels = _NAMESPACE_TOP_LEVELS[_MACOS_WHL],
        expected_regular_roots = _REGULAR_ROOTS[_MACOS_WHL],
        expected_console_scripts = _CONSOLE_SCRIPTS[_MACOS_WHL],
        leaked_top_levels = ["_demo_backend.cpython-311-x86_64-linux-gnu.so"],
        leaked_console_scripts = [],
    )

    _metadata_selection_test(
        name = name + "_known_empty_scripts_patched_test",
        expect_empty_scripts_validation = True,
        expected_console_scripts = [],
        expected_directory_top_levels = _DIRECTORY_TOP_LEVELS[_MACOS_WHL],
        expected_namespace_dirs = _NAMESPACE_DIRS[_MACOS_WHL],
        expected_namespace_entries = _NAMESPACE_ENTRIES[_MACOS_WHL],
        expected_namespace_top_levels = _NAMESPACE_TOP_LEVELS[_MACOS_WHL],
        expected_regular_roots = _REGULAR_ROOTS[_MACOS_WHL],
        expected_top_levels = _TOP_LEVELS[_MACOS_WHL],
        leaked_console_scripts = _CONSOLE_SCRIPTS[_MACOS_WHL],
        leaked_top_levels = [],
        target_under_test = ":__metadata_empty_scripts_patched_fixture",
    )

    _metadata_selection_test(
        name = name + "_known_empty_built_scripts_test",
        expect_empty_scripts_validation = True,
        expected_console_scripts = [],
        expected_directory_top_levels = ["demo"],
        expected_top_levels = ["demo"],
        leaked_console_scripts = [],
        leaked_top_levels = [],
        target_under_test = ":__metadata_declared_sbuild_no_scripts_fixture",
    )

    _metadata_selection_test(
        name = name + "_console_script_only_sbuild_test",
        expected_console_scripts = ["demo=demo.cli:main"],
        expected_layout_known = False,
        expected_scripts_known = True,
        leaked_console_scripts = [],
        leaked_top_levels = [],
        target_under_test = ":__metadata_console_script_only_sbuild_fixture",
    )

    _metadata_miss_test(
        name = name + "_metadata_miss_test",
        target_under_test = ":__metadata_miss_fixture",
    )

    _metadata_miss_test(
        name = name + "_unknown_sbuild_metadata_test",
        target_under_test = ":__metadata_unknown_sbuild_fixture",
    )

    _metadata_selection_test(
        name = name + "_compile_pyc_test",
        target_under_test = ":__metadata_compile_pyc_fixture",
        expected_console_scripts = [],
        expected_directory_top_levels = [],
        expected_scripts_known = False,
        expected_top_levels = ["demo.py"],
        leaked_console_scripts = [],
        leaked_top_levels = [],
    )

    _metadata_selection_test(
        name = name + "_declared_sbuild_test",
        expected_console_scripts = _BUILT_WHEEL_CONSOLE_SCRIPTS,
        expected_directory_top_levels = _BUILT_WHEEL_TOP_LEVELS,
        expected_top_levels = _BUILT_WHEEL_TOP_LEVELS,
        leaked_console_scripts = [],
        leaked_top_levels = [],
        target_under_test = ":__metadata_declared_sbuild_fixture",
    )

def whl_install_suite():
    unittest.suite(
        "whl_sorting_tests",
        whl_sorting_test,
    )
    unittest.suite(
        "abi3_compatibility_tests",
        abi3_compatibility_test,
    )
    unittest.suite(
        "source_specificity_tests",
        source_specificity_test,
    )
    unittest.suite(
        "record_path_tests",
        record_path_test,
    )
    unittest.suite(
        "console_scripts_tests",
        console_scripts_test,
    )
    unittest.suite(
        "site_packages_segments_tests",
        site_packages_segments_test,
    )
    unittest.suite(
        "console_script_tests",
        console_script_test,
    )
    unittest.suite(
        "wheel_layout_metadata_tests",
        wheel_layout_metadata_test,
    )
