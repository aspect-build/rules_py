"""Tests for permissive wheel-collision precedence."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py:defs.bzl", "py_binary", "py_library", "py_test")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _wheel_impl(ctx):
    py_runtime = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    install_tree = ctx.actions.declare_directory(ctx.label.name + ".install")
    major = py_runtime.interpreter_version_info.major
    minor = py_runtime.interpreter_version_info.minor
    command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
metadata="$site/$6"
mkdir -p "$metadata"
printf 'Metadata-Version: 2.1\nName: collision-%s\nVersion: 1.0\nSummary: %s\n' "$5" "$7" > "$metadata/METADATA"
"""
    metadata_name = ctx.attr.metadata_name or "collision_{}-1.0.dist-info".format(ctx.attr.value)
    top_levels = (metadata_name,)
    namespace_top_levels = ()
    namespace_entries = ()
    console_scripts = ()
    if not ctx.attr.metadata_only:
        command += """
mkdir -p "$site/collision_namespace"
printf 'VALUE = %s\n' "$4" > "$site/collision_namespace/shared.py"
printf 'VALUE = %s\n\ndef main():\n    print(VALUE)\n' "$4" > "$site/collision_namespace/$5.py"
"""
        top_levels = ("collision_namespace", metadata_name)
        namespace_top_levels = ("collision_namespace",)
        namespace_entries = (
            "collision_namespace/shared.py",
            "collision_namespace/{}.py".format(ctx.attr.value),
        )
    if ctx.attr.ordinary:
        command += """
printf 'VALUE = %s\n' "$4" > "$site/collision_order.py"
"""
        top_levels += ("collision_order.py",)
        console_scripts = ("collision-order=collision_namespace.{}:main".format(ctx.attr.value),)
    if ctx.attr.root_pth_name:
        command += """
printf 'import sys; sys.path.append("rules_py_pth_%s")\n' "$5" > "$site/$8.pth"
"""
        top_levels += (ctx.attr.root_pth_name + ".pth",)
    ctx.actions.run_shell(
        outputs = [install_tree],
        command = command,
        arguments = [
            install_tree.path,
            str(major),
            str(minor),
            json.encode(ctx.attr.value),
            ctx.attr.value,
            metadata_name,
            ctx.label.name,
            ctx.attr.root_pth_name,
        ],
    )
    site_packages = "/".join([
        segment
        for segment in [
            ctx.label.repo_name or ctx.workspace_name,
            ctx.label.package,
            install_tree.basename,
        ]
        if segment
    ] + ["lib/python{}.{}/site-packages".format(major, minor)])
    wheel = struct(
        top_levels = top_levels,
        layout_complete = ctx.attr.layout_complete,
        namespace_top_levels = namespace_top_levels,
        namespace_entries = namespace_entries,
        namespace_dirs = (),
        regular_roots = (),
        site_packages_rfpath = site_packages,
        console_scripts = console_scripts,
        install_tree = install_tree,
    )
    return [
        DefaultInfo(
            files = depset([install_tree]),
            runfiles = ctx.runfiles(files = [install_tree]),
        ),
        PyInfo(
            imports = depset([site_packages]),
            transitive_sources = depset([install_tree]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        PyWheelsInfo(wheels = depset([wheel])),
    ]

_wheel = rule(
    implementation = _wheel_impl,
    attrs = {
        "layout_complete": attr.bool(default = True),
        "metadata_name": attr.string(),
        "metadata_only": attr.bool(),
        "ordinary": attr.bool(),
        "root_pth_name": attr.string(),
        "value": attr.string(mandatory = True),
    },
    toolchains = [PY_TOOLCHAIN],
)

def _collision_error_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

_collision_error_test = analysistest.make(
    _collision_error_test_impl,
    attrs = {
        "expected_error": attr.string(mandatory = True),
    },
    expect_failure = True,
)

def collision_order_test_suite():
    _wheel(
        name = "_collision_first",
        ordinary = True,
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_collision_second",
        ordinary = True,
        value = "second",
        tags = ["manual"],
    )
    py_library(
        name = "_collision_branch",
        deps = [":_collision_first"],
        tags = ["manual"],
    )
    py_test(
        name = "later_direct_claimant_wins_test",
        srcs = ["test_collision_order.py"],
        args = ["second"],
        main = "test_collision_order.py",
        package_collisions = "ignore",
        deps = [
            ":_collision_branch",
            ":_collision_second",
        ],
    )
    py_test(
        name = "later_transitive_claimant_wins_test",
        srcs = ["test_collision_order.py"],
        args = ["first"],
        main = "test_collision_order.py",
        package_collisions = "ignore",
        deps = [
            ":_collision_second",
            ":_collision_branch",
        ],
    )
    py_binary(
        name = "_collision_error_binary",
        srcs = ["test_collision_order.py"],
        main = "test_collision_order.py",
        package_collisions = "error",
        tags = ["manual"],
        deps = [
            ":_collision_first",
            ":_collision_second",
        ],
    )
    _collision_error_test(
        name = "collision_error_test",
        expected_error = "namespace entry `collision_namespace/shared.py`",
        target_under_test = ":_collision_error_binary",
    )

    _wheel(
        name = "_metadata_collision_second",
        metadata_name = "collision_first-1.0.dist-info",
        tags = ["manual"],
        value = "metadata_second",
    )
    py_binary(
        name = "_metadata_collision_error_binary",
        srcs = ["test_namespace_fallback.py"],
        main = "test_namespace_fallback.py",
        package_collisions = "ignore",
        tags = ["manual"],
        deps = [
            ":_collision_first",
            ":_metadata_collision_second",
        ],
    )
    _collision_error_test(
        name = "metadata_collision_error_test",
        expected_error = "distribution metadata entry `collision_first-1.0.dist-info` selects",
        target_under_test = ":_metadata_collision_error_binary",
    )

    _wheel(
        name = "_metadata_suppressible_first",
        metadata_only = True,
        tags = ["manual"],
        value = "metadata_shared",
    )
    _wheel(
        name = "_metadata_suppressible_second",
        metadata_only = True,
        tags = ["manual"],
        value = "metadata_shared",
    )
    py_test(
        name = "metadata_collision_suppression_test",
        srcs = ["test_metadata_collision_suppression.py"],
        main = "test_metadata_collision_suppression.py",
        package_collisions = "ignore",
        deps = [
            ":_metadata_suppressible_first",
            ":_metadata_suppressible_second",
        ],
    )

    _wheel(
        name = "_collision_incomplete",
        layout_complete = False,
        ordinary = True,
        tags = ["manual"],
        value = "incomplete",
    )
    py_binary(
        name = "_incomplete_collision_error_binary",
        srcs = ["test_collision_order.py"],
        main = "test_collision_order.py",
        package_collisions = "error",
        tags = ["manual"],
        deps = [
            ":_collision_first",
            ":_collision_incomplete",
        ],
    )
    _collision_error_test(
        name = "incomplete_collision_error_test",
        expected_error = "namespace entry `collision_namespace/shared.py`",
        target_under_test = ":_incomplete_collision_error_binary",
    )

    _wheel(
        name = "_pth_collision_complete",
        metadata_only = True,
        root_pth_name = "collision_marker",
        tags = ["manual"],
        value = "complete",
    )
    _wheel(
        name = "_pth_collision_incomplete",
        layout_complete = False,
        metadata_only = True,
        root_pth_name = "collision_marker",
        tags = ["manual"],
        value = "pth_incomplete",
    )
    py_binary(
        name = "_incomplete_pth_collision_error_binary",
        srcs = ["test_namespace_fallback.py"],
        main = "test_namespace_fallback.py",
        package_collisions = "error",
        tags = ["manual"],
        deps = [
            ":_pth_collision_incomplete",
            ":_pth_collision_complete",
        ],
    )
    _collision_error_test(
        name = "incomplete_pth_collision_error_test",
        expected_error = "root `.pth` file `collision_marker.pth` selects",
        target_under_test = ":_incomplete_pth_collision_error_binary",
    )

    _wheel(
        name = "_pth_runtime_complete_loser",
        metadata_only = True,
        root_pth_name = "runtime_collision_marker",
        tags = ["manual"],
        value = "suppressed",
    )
    _wheel(
        name = "_pth_runtime_incomplete",
        layout_complete = False,
        metadata_only = True,
        root_pth_name = "runtime_collision_marker",
        tags = ["manual"],
        value = "incomplete",
    )
    py_test(
        name = "incomplete_layout_pth_test",
        srcs = ["test_incomplete_layout_pth.py"],
        isolated = False,
        main = "test_incomplete_layout_pth.py",
        package_collisions = "ignore",
        deps = [
            ":_pth_collision_complete",
            ":_pth_runtime_complete_loser",
            ":_pth_runtime_incomplete",
        ],
    )

    _wheel(
        name = "_namespace_first",
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_namespace_second",
        value = "second",
        tags = ["manual"],
    )
    py_test(
        name = "namespace_fallback_order_test",
        srcs = ["test_namespace_fallback.py"],
        args = [
            "second",
            "first",
        ],
        main = "test_namespace_fallback.py",
        package_collisions = "ignore",
        deps = [
            ":_namespace_first",
            ":_namespace_second",
        ],
    )
