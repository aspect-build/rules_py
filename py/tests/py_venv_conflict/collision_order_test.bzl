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
mkdir -p "$site/atomic" "$site/collision_namespace" "$site/$5_sibling"
printf 'VALUE = %s\n\ndef main():\n    print(VALUE)\n' "$4" > "$site/collision_order.py"
printf '' > "$site/atomic/__init__.py"
printf 'VALUE = %s\n' "$4" > "$site/atomic/shared.py"
printf 'VALUE = %s\n' "$4" > "$site/atomic/only_$5.py"
printf 'VALUE = %s\n' "$4" > "$site/collision_namespace/shared.py"
printf 'VALUE = %s\n' "$4" > "$site/collision_namespace/$5.py"
printf 'VALUE = %s\n' "$4" > "$site/$5_sibling/value.py"
"""
        arguments = [
            install_tree.path,
            str(major),
            str(minor),
            json.encode(ctx.attr.value),
            ctx.attr.value,
        ]
        top_levels = ("atomic", "collision_namespace", "collision_order.py", "{}_sibling".format(ctx.attr.value))
        directory_top_levels = ("atomic", "collision_namespace", "{}_sibling".format(ctx.attr.value))
        namespace_top_levels = ("collision_namespace",)
        namespace_entries = (
            "collision_namespace/shared.py",
            "collision_namespace/{}.py".format(ctx.attr.value),
        )
        console_scripts = ("collision-order=collision_order:main",)
    elif ctx.attr.kind == "console":
        command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
printf 'def main():\n    return 0\n' > "$site/$5.py"
"""
        arguments = [install_tree.path, str(major), str(minor), json.encode(ctx.attr.value), ctx.attr.value]
        top_levels = ("{}.py".format(ctx.attr.value),)
        directory_top_levels = ()
        namespace_top_levels = ()
        namespace_entries = ()
        console_scripts = ("shared-script={}:main".format(ctx.attr.value),)
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
        console_scripts = ()
    elif ctx.attr.kind in ("deep", "shallow"):
        command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/prefix_namespace/package/deep"
printf 'VALUE = %%s\n' "$4" > "$site/prefix_namespace/package/%s.py"
""" % ("deep/value" if ctx.attr.kind == "deep" else "shallow")
        if ctx.attr.kind == "deep":
            # This sibling sorts between `package` and `package/deep/value.py`.
            # Prefix detection must therefore check ancestors, not just
            # lexicographically adjacent entries.
            command += "printf 'VALUE = %s\n' \"$4\" > \"$site/prefix_namespace/package.py\"\n"
        if ctx.attr.kind == "shallow":
            command += "printf '' > \"$site/prefix_namespace/package/__init__.py\"\n"
        arguments = [install_tree.path, str(major), str(minor), json.encode(ctx.attr.value)]
        top_levels = ("prefix_namespace",)
        directory_top_levels = top_levels
        namespace_top_levels = top_levels
        namespace_entries = (
            "prefix_namespace/package/deep/value.py",
            "prefix_namespace/package.py",
        ) if ctx.attr.kind == "deep" else (
            "prefix_namespace/package",
        )
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
        namespace_top_levels = ()
        namespace_entries = ()
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
        namespace_entries_known = ctx.attr.namespace_entries_known,
        site_packages_rfpath = site_packages,
        console_scripts = console_scripts,
        scripts_known = True,
        install_tree = install_tree if ctx.attr.provide_install_tree else None,
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
            values = ["console", "deep", "graft", "other", "regular", "shallow", "simple"],
        ),
        "namespace_entries_known": attr.bool(default = True),
        "provide_install_tree": attr.bool(default = True),
        "value": attr.string(mandatory = True),
    },
    toolchains = [PY_TOOLCHAIN],
)

def _collision_error_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "top-level `atomic`")
    return analysistest.end(env)

_collision_error_test = analysistest.make(
    _collision_error_test_impl,
    expect_failure = True,
)

def _console_collision_error_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "console script `shared-script`")
    return analysistest.end(env)

_console_collision_error_test = analysistest.make(
    _console_collision_error_test_impl,
    expect_failure = True,
)

def _missing_install_tree_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires a full merge because namespace entries `other/from_other.py` and `other/from_other.py` overlap")
    asserts.expect_failure(env, "have no install_tree")
    return analysistest.end(env)

_missing_install_tree_test = analysistest.make(
    _missing_install_tree_test_impl,
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
        name = "_console_first",
        kind = "console",
        value = "console_first",
        tags = ["manual"],
    )
    _wheel(
        name = "_console_second",
        kind = "console",
        value = "console_second",
        tags = ["manual"],
    )
    py_binary(
        name = "_console_collision_error_binary",
        srcs = ["test_namespace_prefix.py"],
        deps = [
            ":_console_first",
            ":_console_second",
        ],
        package_collisions = "error",
        tags = ["manual"],
    )
    _console_collision_error_test(
        name = "console_collision_error_test",
        target_under_test = ":_console_collision_error_binary",
    )

    _wheel(
        name = "_missing_tree_first",
        kind = "other",
        provide_install_tree = False,
        value = "missing",
        tags = ["manual"],
    )
    _wheel(
        name = "_missing_tree_second",
        kind = "other",
        value = "present",
        tags = ["manual"],
    )
    py_binary(
        name = "_missing_install_tree_binary",
        srcs = ["test_namespace_prefix.py"],
        deps = [
            ":_missing_tree_first",
            ":_missing_tree_second",
        ],
        package_collisions = "ignore",
        tags = ["manual"],
    )
    _missing_install_tree_test(
        name = "missing_install_tree_test",
        target_under_test = ":_missing_install_tree_binary",
    )

    _wheel(
        name = "_prefix_shallow",
        kind = "shallow",
        value = "shallow",
        tags = ["manual"],
    )
    _wheel(
        name = "_prefix_deep",
        kind = "deep",
        value = "deep",
        tags = ["manual"],
    )
    for name, deps in {
        "deep_then_shallow": [":_prefix_deep", ":_prefix_shallow"],
        "shallow_then_deep": [":_prefix_shallow", ":_prefix_deep"],
    }.items():
        py_test(
            name = "namespace_prefix_{}_test".format(name),
            srcs = ["test_namespace_prefix.py"],
            deps = deps,
            package_collisions = "warning" if name == "deep_then_shallow" else "ignore",
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
    py_test(
        name = "mixed_regular_namespace_graft_wins_test",
        srcs = ["test_regular_span_collision_order.py"],
        args = ["graft"],
        deps = [
            ":_mixed_other",
            ":_mixed_regular",
            ":_mixed_graft",
        ],
        package_collisions = "ignore",
    )
    py_test(
        name = "mixed_regular_namespace_regular_wins_test",
        srcs = ["test_regular_span_collision_order.py"],
        args = ["regular"],
        deps = [
            ":_mixed_other",
            ":_mixed_graft",
            ":_mixed_regular",
        ],
        package_collisions = "ignore",
    )
