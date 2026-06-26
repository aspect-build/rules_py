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
    top_level_dirs = ()
    namespace_top_levels = ()
    namespace_entries = ()
    native_roots = ()
    console_scripts = ()
    if not ctx.attr.metadata_only:
        command += """
mkdir -p "$site/collision_namespace"
printf 'VALUE = %s\n' "$4" > "$site/collision_namespace/shared.py"
printf 'VALUE = %s\n\ndef main():\n    print(VALUE)\n' "$4" > "$site/collision_namespace/$5.py"
"""
        top_levels = ("collision_namespace", metadata_name)
        top_level_dirs = ("collision_namespace",)
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
    if ctx.attr.regular:
        command += """
mkdir -p "$site/collision_order"
printf '' > "$site/collision_order/__init__.py"
printf 'from pathlib import Path\n\nVALUE = %s\n\ndef sibling_value():\n    return (Path(__file__).resolve().parent.parent / "collision_order.libs" / "marker.txt").read_text()\n' "$4" > "$site/collision_order/$5.py"
"""
        top_levels += ("collision_order",)
        top_level_dirs += ("collision_order",)
    if ctx.attr.native_root:
        command += """
mkdir -p "$site/collision_order.libs"
printf '%s' "$5" > "$site/collision_order.libs/marker.txt"
"""
        top_levels += ("collision_order.libs",)
        top_level_dirs += ("collision_order.libs",)
        native_roots = ("collision_order",)
    if ctx.attr.native_namespace:
        command += """
mkdir -p "$site/collision_order"
printf 'VALUE = %s\n' "$4" > "$site/collision_order/$5.py"
printf 'native' > "$site/collision_order/native_extension.so"
"""
        top_levels += ("collision_order",)
        top_level_dirs += ("collision_order",)
        namespace_top_levels += ("collision_order",)
        namespace_entries += (
            "collision_order/{}.py".format(ctx.attr.value),
            "collision_order/native_extension.so",
        )
        native_roots = ("collision_order",)
    if ctx.attr.mixed_regular:
        command += """
mkdir -p "$site/collision_mixed"
printf '' > "$site/collision_mixed/__init__.py"
printf 'VALUE = %s\n' "$4" > "$site/collision_mixed/regular.py"
"""
        top_levels += ("collision_mixed",)
        top_level_dirs += ("collision_mixed",)
    if ctx.attr.mixed_namespace:
        command += """
mkdir -p "$site/collision_mixed"
printf 'VALUE = %s\n' "$4" > "$site/collision_mixed/namespace.py"
"""
        top_levels += ("collision_mixed",)
        top_level_dirs += ("collision_mixed",)
        namespace_top_levels += ("collision_mixed",)
        namespace_entries += ("collision_mixed/namespace.py",)
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
        namespace_top_levels = namespace_top_levels,
        namespace_entries = namespace_entries,
        namespace_dirs = (),
        regular_roots = (),
        top_level_dirs = top_level_dirs,
        native_roots = native_roots,
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
        "metadata_name": attr.string(),
        "metadata_only": attr.bool(),
        "mixed_namespace": attr.bool(),
        "mixed_regular": attr.bool(),
        "native_namespace": attr.bool(),
        "native_root": attr.bool(),
        "ordinary": attr.bool(),
        "regular": attr.bool(),
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

    _wheel(
        name = "_regular_first",
        regular = True,
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_regular_second",
        regular = True,
        value = "second",
        tags = ["manual"],
    )
    py_test(
        name = "regular_directory_union_test",
        srcs = ["test_collision_union.py"],
        main = "test_collision_union.py",
        package_collisions = "ignore",
        deps = [
            ":_regular_first",
            ":_regular_second",
        ],
    )

    _wheel(
        name = "_native_regular_first",
        regular = True,
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_native_regular_second",
        native_root = True,
        regular = True,
        value = "second",
        tags = ["manual"],
    )
    py_test(
        name = "native_directory_collision_test",
        srcs = ["test_native_collision.py"],
        main = "test_native_collision.py",
        package_collisions = "ignore",
        deps = [
            ":_native_regular_first",
            ":_native_regular_second",
        ],
    )

    _wheel(
        name = "_native_namespace_regular_first",
        regular = True,
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_native_namespace_second",
        native_namespace = True,
        value = "second",
        tags = ["manual"],
    )
    py_test(
        name = "native_namespace_regular_first_collision_test",
        srcs = ["test_native_top_level_collision.py"],
        main = "test_native_top_level_collision.py",
        package_collisions = "ignore",
        deps = [
            ":_native_namespace_regular_first",
            ":_native_namespace_second",
        ],
    )

    _wheel(
        name = "_mixed_regular",
        mixed_regular = True,
        value = "regular",
        tags = ["manual"],
    )
    _wheel(
        name = "_mixed_namespace",
        mixed_namespace = True,
        value = "namespace",
        tags = ["manual"],
    )
    py_test(
        name = "mixed_directory_union_test",
        srcs = ["test_collision_mixed_union.py"],
        main = "test_collision_mixed_union.py",
        package_collisions = "ignore",
        deps = [
            ":_mixed_regular",
            ":_mixed_namespace",
        ],
    )
