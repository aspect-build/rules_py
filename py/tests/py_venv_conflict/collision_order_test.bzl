"""Tests for permissive wheel-collision behavior."""

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
mkdir -p "$site"
"""
    top_levels = ()
    namespace_top_levels = ()
    namespace_entries = ()
    console_scripts = ()
    if ctx.attr.kind in ("namespace", "ordered"):
        command += """
mkdir -p "$site/collision_namespace"
printf 'VALUE = %s\n' "$4" > "$site/collision_namespace/shared.py"
printf 'VALUE = %s\n\ndef main():\n    print(VALUE)\n' "$4" > "$site/collision_namespace/$5.py"
"""
        top_levels = ("collision_namespace",)
        namespace_top_levels = top_levels
        namespace_entries = (
            "collision_namespace/shared.py",
            "collision_namespace/{}.py".format(ctx.attr.value),
        )
    if ctx.attr.kind == "ordered":
        console_scripts = ("collision-order=collision_namespace.{}:main".format(ctx.attr.value),)
    elif ctx.attr.kind == "regular":
        command += """
mkdir -p "$site/collision_order"
printf '' > "$site/collision_order/__init__.py"
printf 'VALUE = %s\n' "$4" > "$site/collision_order/$5.py"
"""
        top_levels = ("collision_order",)
    elif ctx.attr.kind == "file":
        command += """
printf 'VALUE = %s\n' "$4" > "$site/collision_file.py"
"""
        top_levels = ("collision_file.py",)
    ctx.actions.run_shell(
        outputs = [install_tree],
        command = command,
        arguments = [
            install_tree.path,
            str(major),
            str(minor),
            json.encode(ctx.attr.value),
            ctx.attr.value,
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
        "kind": attr.string(mandatory = True, values = ["file", "namespace", "ordered", "regular"]),
        "value": attr.string(mandatory = True),
    },
    toolchains = [PY_TOOLCHAIN],
)

def _collision_error_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "namespace entry `collision_namespace/shared.py`")
    return analysistest.end(env)

_collision_error_test = analysistest.make(
    _collision_error_test_impl,
    expect_failure = True,
)

def collision_order_test_suite():
    _wheel(
        name = "_collision_first",
        kind = "ordered",
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_collision_second",
        kind = "ordered",
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
        target_under_test = ":_collision_error_binary",
    )

    _wheel(
        name = "_namespace_first",
        kind = "namespace",
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_namespace_second",
        kind = "namespace",
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
        kind = "regular",
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_regular_second",
        kind = "regular",
        value = "second",
        tags = ["manual"],
    )
    py_test(
        name = "regular_directory_union_test",
        srcs = ["test_collision_union.py"],
        package_collisions = "ignore",
        deps = [
            ":_regular_first",
            ":_regular_second",
        ],
    )

    _wheel(
        name = "_file_first",
        kind = "file",
        value = "first",
        tags = ["manual"],
    )
    _wheel(
        name = "_file_second",
        kind = "file",
        value = "second",
        tags = ["manual"],
    )
    py_binary(
        name = "_file_collision_binary",
        srcs = ["test_collision_union.py"],
        package_collisions = "ignore",
        tags = ["manual"],
        deps = [
            ":_file_first",
            ":_file_second",
        ],
    )
