"""Unit + analysis tests for whl_install wheel selection and metadata."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//py/private:providers.bzl", "PyWheelsInfo")
load(":repository.bzl", "compatible_python_tags", "parse_console_script", "parse_record_path", "select_key", "site_packages_segments", "sort_select_arms", "source_specificity")
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

# Built-from-source fallback: contents are unknowable at repo-fetch time, so
# no metadata entry exists for it.
_SBUILD_WHL = "demo-1.0.0-py3-none-any.whl"

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

_NAMESPACE_TOP_LEVELS = {
    _MACOS_WHL: ["demo_ns"],
}

_CONSOLE_SCRIPTS = {
    _LINUX_WHL: ["demo=demo.cli:main"],
    _MACOS_WHL: [
        "demo-mac=demo.cli:mac_main",
        "demo=demo.cli:main",
    ],
}

def _metadata_selection_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    wheels = target[PyWheelsInfo].wheels.to_list()
    asserts.equals(env, 1, len(wheels), "expected exactly one wheel struct in PyWheelsInfo")

    wheel = wheels[0]
    asserts.true(env, wheel.install_tree != None, "wheel record must retain its install tree")
    asserts.equals(env, tuple(ctx.attr.expected_top_levels), wheel.top_levels)
    asserts.equals(env, tuple(ctx.attr.expected_namespace_top_levels), wheel.namespace_top_levels)
    asserts.equals(env, tuple(ctx.attr.expected_console_scripts), wheel.console_scripts)

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

    return analysistest.end(env)

_metadata_selection_test = analysistest.make(
    _metadata_selection_test_impl,
    attrs = {
        "expected_top_levels": attr.string_list(),
        "expected_namespace_top_levels": attr.string_list(),
        "expected_console_scripts": attr.string_list(),
        "leaked_top_levels": attr.string_list(),
        "leaked_console_scripts": attr.string_list(),
    },
)

def metadata_selection_test_suite(name):
    """Fixtures + analysis tests for per-configuration metadata selection.

    Args:
        name: prefix for the generated test targets.
    """

    for basename in [_LINUX_WHL, _MACOS_WHL, _SBUILD_WHL]:
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
        ("__metadata_sbuild_fixture", _SBUILD_WHL),
    ]:
        whl_install(
            name = fixture_name,
            src = src,
            top_levels = _TOP_LEVELS,
            namespace_top_levels = _NAMESPACE_TOP_LEVELS,
            console_scripts = _CONSOLE_SCRIPTS,
            tags = ["manual"],
        )

    _metadata_selection_test(
        name = name + "_linux_test",
        target_under_test = ":__metadata_linux_fixture",
        expected_top_levels = _TOP_LEVELS[_LINUX_WHL],
        expected_namespace_top_levels = [],
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
        expected_namespace_top_levels = _NAMESPACE_TOP_LEVELS[_MACOS_WHL],
        expected_console_scripts = _CONSOLE_SCRIPTS[_MACOS_WHL],
        leaked_top_levels = ["_demo_backend.cpython-311-x86_64-linux-gnu.so"],
        leaked_console_scripts = [],
    )

    _metadata_selection_test(
        name = name + "_sbuild_fallback_test",
        target_under_test = ":__metadata_sbuild_fixture",
        expected_top_levels = [],
        expected_namespace_top_levels = [],
        expected_console_scripts = [],
        leaked_top_levels = [],
        leaked_console_scripts = [],
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
        "site_packages_segments_tests",
        site_packages_segments_test,
    )
    unittest.suite(
        "console_script_tests",
        console_script_test,
    )
