"""Analysis test for top-level regular-package merge outputs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py:defs.bzl", "py_binary", "py_image_layer", "py_venv")
load("//py/private:providers.bzl", "PyWheelsInfo")

def _wheel_impl(ctx):
    install_tree = ctx.actions.declare_directory(ctx.label.name + ".install")
    ctx.actions.run_shell(
        outputs = [install_tree],
        command = "mkdir -p \"$1\"",
        arguments = [install_tree.path],
    )
    site_packages = "/".join([
        ctx.workspace_name,
        ctx.label.package,
        install_tree.basename,
        "lib/python3/site-packages",
    ])
    wheel = {
        "console_scripts": (),
        "namespace_dirs": tuple(ctx.attr.namespace_dirs),
        "namespace_entries": tuple(ctx.attr.namespace_dirs),
        "namespace_top_levels": tuple(ctx.attr.top_levels),
        "regular_roots": tuple(ctx.attr.regular_roots),
        "site_packages_rfpath": site_packages,
        "top_levels": tuple(ctx.attr.top_levels),
    }
    if ctx.attr.expose_install_tree:
        wheel["install_tree"] = install_tree
    return [
        DefaultInfo(
            files = depset([install_tree]),
            runfiles = ctx.runfiles(files = [install_tree]),
        ),
        PyInfo(
            imports = depset(),
            transitive_sources = depset([install_tree]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        PyWheelsInfo(wheels = depset([struct(**wheel)])),
    ]

_wheel = rule(
    implementation = _wheel_impl,
    attrs = {
        "expose_install_tree": attr.bool(default = True),
        "namespace_dirs": attr.string_list(),
        "regular_roots": attr.string_list(),
        "top_levels": attr.string_list(),
    },
)

def _merge_outputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    merge_actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "PySiteMerge"
    ]

    asserts.equals(env, 2, len(merge_actions))
    outputs = [
        output
        for action in merge_actions
        for output in action.outputs.to_list()
    ]
    asserts.equals(env, 2, len(outputs))
    if len(outputs) == 2:
        paths = [output.short_path for output in outputs]
        runfiles = target[DefaultInfo].default_runfiles.files.to_list()
        asserts.true(env, all([output.is_directory for output in outputs]))
        asserts.true(env, all([output in runfiles for output in outputs]))
        merge_keys = {
            path.split("/_merged/", 1)[1]: True
            for path in paths
            if "/_merged/" in path
        }
        asserts.equals(env, {"alpha": True, "beta": True}, merge_keys)

        dependency_files = target[OutputGroupInfo]._venv_dependency_files.to_list()
        asserts.equals(env, {output.path: True for output in outputs}, {
            output.path: True
            for output in dependency_files
        })

        source_counts = {}
        for action in merge_actions:
            into_roots = [
                action.argv[i + 1].rsplit("/", 1)[-1]
                for i in range(len(action.argv) - 1)
                if action.argv[i] == "--into"
            ]
            asserts.equals(env, 1, len(into_roots))
            source_counts[into_roots[0]] = len([
                arg
                for arg in action.argv
                if arg == "--src"
            ])
        asserts.equals(env, {"alpha": 3, "beta": 2}, source_counts)
        alpha_action = [
            action
            for action in merge_actions
            if any([arg.endswith("/alpha") for arg in action.argv])
        ][0]
        asserts.true(env, any([
            "_merge_wheel_extra.install" in arg
            for arg in alpha_action.argv
        ]))
        asserts.false(env, any([
            "_merge_wheel_legacy.install" in arg
            for arg in alpha_action.argv
        ]))
        all_output_paths = [
            output.short_path
            for action in analysistest.target_actions(env)
            for output in action.outputs.to_list()
        ]
        merged_links = {
            path.rsplit("/site-packages/", 1)[-1]: True
            for path in all_output_paths
            if path.endswith("/site-packages/alpha") or path.endswith("/site-packages/beta")
        }
        asserts.equals(env, {"alpha": True, "beta": True}, merged_links)

    return analysistest.end(env)

_merge_outputs_test = analysistest.make(_merge_outputs_test_impl)

def _merge_layer_outputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    dependency_actions = [
        action
        for action in actions
        if any([output.basename.endswith("_squashed.tar.gz") for output in action.outputs.to_list()])
    ]
    source_actions = [
        action
        for action in actions
        if any([output.basename.endswith("_default.tar.gz") for output in action.outputs.to_list()])
    ]

    asserts.equals(env, 1, len(dependency_actions))
    asserts.equals(env, 1, len(source_actions))
    if len(dependency_actions) == 1 and len(source_actions) == 1:
        dependency_inputs = [file.path for file in dependency_actions[0].inputs.to_list()]
        source_inputs = [file.path for file in source_actions[0].inputs.to_list()]
        asserts.equals(env, 2, len([path for path in dependency_inputs if "/_merged/" in path]))
        asserts.false(env, any(["/_merged/" in path for path in source_inputs]))

    return analysistest.end(env)

_merge_layer_outputs_test = analysistest.make(_merge_layer_outputs_test_impl)

def _missing_install_tree_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "do not expose install_tree outputs")
    return analysistest.end(env)

_missing_install_tree_test = analysistest.make(
    _missing_install_tree_test_impl,
    expect_failure = True,
)

def merge_outputs_test_suite():
    merge_deps = [
        ":_merge_wheel_grafts",
        ":_merge_wheel_extra",
        ":_merge_wheel_legacy",
        ":_merge_wheel_regular",
    ]
    _wheel(
        name = "_merge_wheel_regular",
        regular_roots = [
            "alpha/left",
            "alpha/right",
            "beta/root",
        ],
        top_levels = ["alpha", "beta"],
        tags = ["manual"],
    )
    _wheel(
        name = "_merge_wheel_grafts",
        namespace_dirs = [
            "alpha/left",
            "alpha/right",
            "beta/root",
        ],
        top_levels = ["alpha", "beta"],
        tags = ["manual"],
    )
    _wheel(
        name = "_merge_wheel_extra",
        namespace_dirs = ["alpha/other"],
        top_levels = ["alpha"],
        tags = ["manual"],
    )
    _wheel(
        name = "_merge_wheel_legacy",
        expose_install_tree = False,
        namespace_dirs = ["alpha/legacy"],
        top_levels = ["alpha"],
        tags = ["manual"],
    )
    py_binary(
        name = "_merge_outputs_binary",
        srcs = ["merge_outputs_test.py"],
        deps = merge_deps,
        tags = ["manual"],
    )
    py_venv(
        name = "_merge_outputs_venv",
        srcs = ["merge_outputs_test.py"],
        deps = merge_deps,
        tags = ["manual"],
    )
    py_image_layer(
        name = "_merge_outputs_layers",
        binary = ":_merge_outputs_binary",
        tags = ["manual"],
    )
    _merge_outputs_test(
        name = "merge_outputs_test",
        target_under_test = ":_merge_outputs_binary",
    )
    _merge_outputs_test(
        name = "merge_outputs_venv_test",
        target_under_test = ":_merge_outputs_venv",
    )
    _merge_layer_outputs_test(
        name = "merge_layer_outputs_test",
        target_under_test = ":_merge_outputs_layers",
    )

    _wheel(
        name = "_missing_tree_regular",
        expose_install_tree = False,
        regular_roots = ["conflict/root"],
        top_levels = ["conflict"],
        tags = ["manual"],
    )
    _wheel(
        name = "_missing_tree_graft",
        namespace_dirs = ["conflict/root"],
        top_levels = ["conflict"],
        tags = ["manual"],
    )
    py_binary(
        name = "_missing_tree_binary",
        srcs = ["merge_outputs_test.py"],
        deps = [
            ":_missing_tree_graft",
            ":_missing_tree_regular",
        ],
        tags = ["manual"],
    )
    _missing_install_tree_test(
        name = "missing_install_tree_test",
        target_under_test = ":_missing_tree_binary",
    )
