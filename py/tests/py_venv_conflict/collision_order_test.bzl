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
    if ctx.attr.kind == "simple":
        command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/collision_namespace"
printf 'VALUE = %s\n\ndef main():\n    print(VALUE)\n' "$4" > "$site/collision_order.py"
printf 'VALUE = %s\n' "$4" > "$site/collision_namespace/shared.py"
printf 'VALUE = %s\n' "$4" > "$site/collision_namespace/$5.py"
"""
        arguments = [
            install_tree.path,
            str(major),
            str(minor),
            json.encode(ctx.attr.value),
            ctx.attr.value,
        ]
        top_levels = ("collision_namespace", "collision_order.py")
        directory_top_levels = ("collision_namespace",)
        namespace_top_levels = ("collision_namespace",)
        namespace_entries = (
            "collision_namespace/shared.py",
            "collision_namespace/{}.py".format(ctx.attr.value),
        )
        namespace_dirs = ()
        regular_roots = ()
        console_scripts = ("collision-order=collision_order:main",)
    elif ctx.attr.kind == "other":
        command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/other"
printf 'VALUE = %s\n' "$4" > "$site/other/from_other.py"
"""
        arguments = [install_tree.path, str(major), str(minor), json.encode(ctx.attr.value)]
        top_levels = ("other",)
        directory_top_levels = top_levels
        namespace_top_levels = top_levels
        namespace_entries = ("other/from_other.py",)
        namespace_dirs = ()
        regular_roots = ()
        console_scripts = ()
    elif ctx.attr.kind == "regular":
        command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/mixed/root"
printf '' > "$site/mixed/root/__init__.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/root/collision.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/sibling.py"
"""
        arguments = [install_tree.path, str(major), str(minor), json.encode(ctx.attr.value)]
        top_levels = ("mixed",)
        directory_top_levels = top_levels
        namespace_top_levels = top_levels
        namespace_entries = (
            "mixed/root/__init__.py",
            "mixed/root/collision.py",
            "mixed/sibling.py",
        )
        namespace_dirs = ()
        regular_roots = ("mixed/root",)
        console_scripts = ()
    else:
        command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/mixed/root" "$site/other"
printf 'VALUE = %s\n' "$4" > "$site/mixed/root/collision.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/sibling.py"
printf 'VALUE = %s\n' "$4" > "$site/other/from_graft.py"
"""
        arguments = [install_tree.path, str(major), str(minor), json.encode(ctx.attr.value)]
        top_levels = ("mixed", "other")
        directory_top_levels = top_levels
        namespace_top_levels = top_levels
        namespace_entries = (
            "mixed/root/collision.py",
            "mixed/sibling.py",
            "other/from_graft.py",
        )
        namespace_dirs = ("mixed/root",)
        regular_roots = ()
        console_scripts = ()
    ctx.actions.run_shell(
        outputs = [install_tree],
        command = command,
        arguments = arguments,
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
        directory_top_levels = directory_top_levels,
        layout_known = True,
        namespace_top_levels = namespace_top_levels,
        namespace_entries = namespace_entries,
        namespace_dirs = namespace_dirs,
        regular_roots = regular_roots,
        site_packages_rfpath = site_packages,
        console_scripts = console_scripts,
        scripts_known = True,
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
        PyWheelsInfo(wheels = depset([wheel], order = "postorder")),
    ]

_wheel = rule(
    implementation = _wheel_impl,
    attrs = {
        "kind": attr.string(
            mandatory = True,
            values = ["graft", "other", "regular", "simple"],
        ),
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
        name = "_collision_transitive",
        kind = "simple",
        value = "transitive",
        tags = ["manual"],
    )
    _wheel(
        name = "_collision_direct",
        kind = "simple",
        value = "direct",
        tags = ["manual"],
    )
    py_library(
        name = "_collision_branch",
        deps = [":_collision_transitive"],
        tags = ["manual"],
    )
    py_test(
        name = "direct_collision_requirement_wins_test",
        srcs = ["test_collision_order.py"],
        args = ["direct"],
        deps = [
            ":_collision_branch",
            ":_collision_direct",
        ],
        package_collisions = "ignore",
    )
    py_test(
        name = "later_collision_dependency_wins_test",
        srcs = ["test_collision_order.py"],
        args = ["transitive"],
        deps = [
            ":_collision_direct",
            ":_collision_transitive",
        ],
        package_collisions = "ignore",
    )
    py_binary(
        name = "_collision_error_binary",
        srcs = ["test_collision_order.py"],
        deps = [
            ":_collision_transitive",
            ":_collision_direct",
        ],
        package_collisions = "error",
        tags = ["manual"],
    )
    _collision_error_test(
        name = "collision_error_test",
        target_under_test = ":_collision_error_binary",
    )

    _wheel(
        name = "_mixed_other",
        kind = "other",
        value = "other",
        tags = ["manual"],
    )
    _wheel(
        name = "_mixed_regular",
        kind = "regular",
        value = "regular",
        tags = ["manual"],
    )
    _wheel(
        name = "_mixed_graft",
        kind = "graft",
        value = "graft",
        tags = ["manual"],
    )
    for kind in ["merge", "sibling"]:
        py_test(
            name = "regular_span_{}_collision_order_test".format(kind),
            srcs = ["test_regular_span_collision_order.py"],
            args = [kind],
            deps = [
                ":_mixed_other",
                ":_mixed_regular",
                ":_mixed_graft",
            ],
            package_collisions = "ignore",
        )
