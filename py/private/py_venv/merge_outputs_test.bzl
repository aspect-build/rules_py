"""Analysis test for top-level regular-package merge outputs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py:defs.bzl", "py_binary", "py_image_layer", "py_venv")
load("//py/private:providers.bzl", "PyVenvLayoutInfo", "PyWheelsInfo")

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
        "directory_top_levels": tuple(ctx.attr.directory_top_levels),
        "namespace_dirs": tuple(ctx.attr.namespace_dirs),
        "namespace_entries": tuple(ctx.attr.namespace_entries),
        "namespace_top_levels": tuple(ctx.attr.namespace_top_levels),
        "regular_roots": tuple(ctx.attr.regular_roots),
        "topology_known": ctx.attr.topology_known,
        "site_packages_rfpath": site_packages,
        "top_levels": tuple(ctx.attr.top_levels),
    }
    if ctx.attr.expose_install_tree:
        wheel["install_tree"] = install_tree
    return [
        DefaultInfo(
            files = depset([install_tree]),
        ),
        PyInfo(
            imports = depset([site_packages]),
            transitive_sources = depset([install_tree]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        PyWheelsInfo(wheels = depset([struct(**wheel)])),
    ]

# Match the production wheel producer kind consumed by _layer_aspect.
whl_install = rule(
    implementation = _wheel_impl,
    attrs = {
        "expose_install_tree": attr.bool(default = True),
        "directory_top_levels": attr.string_list(),
        "namespace_dirs": attr.string_list(),
        "namespace_entries": attr.string_list(),
        "namespace_top_levels": attr.string_list(),
        "regular_roots": attr.string_list(),
        "top_levels": attr.string_list(),
        "topology_known": attr.bool(default = True),
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
        wheel_targets = [
            file
            for file in runfiles
            if file.basename.endswith(".install")
        ]
        asserts.equals(env, 6, len(wheel_targets))

        pth_actions = [
            action
            for action in analysistest.target_actions(env)
            if any([
                output.basename == target.label.name + ".pth"
                for output in action.outputs.to_list()
            ])
        ]
        asserts.equals(env, 1, len(pth_actions))
        if len(pth_actions) == 1:
            if ctx.attr.expected_wheel_aliases:
                asserts.true(env, "site.addsitedir" in pth_actions[0].content)
                asserts.true(env, '"_wheels"' in pth_actions[0].content)
            else:
                asserts.true(env, "site.addsitedir" in pth_actions[0].content)
            asserts.true(env, "_merge_wheel_legacy.install" in pth_actions[0].content)
        asserts.true(env, all([output.is_directory for output in outputs]))
        asserts.true(env, all([output in runfiles for output in outputs]))
        merge_keys = {
            path.rsplit("/site-packages/", 1)[1]: True
            for path in paths
            if "/site-packages/" in path
        }
        asserts.equals(env, {
            "alpha": True,
            "beta": True,
        }, merge_keys)

        layout = target[PyVenvLayoutInfo]
        wheel_aliases = layout.wheel_aliases.to_list()
        asserts.equals(env, ctx.attr.expected_wheel_aliases, len(wheel_aliases))
        dependency_files = layout.dependency_files.to_list()
        asserts.equals(env, {output.path: True for output in outputs}, {
            output.path: True
            for output in dependency_files
        })
        wheel_links = layout.wheel_links.to_list()
        asserts.equals(env, ctx.attr.expected_wheel_links, len(wheel_links))
        metadata_links = [
            link
            for link in wheel_links
            if link.link.basename == "direct-1.0.dist-info"
        ]
        asserts.equals(env, ctx.attr.expected_metadata_links, len(metadata_links))
        direct_links = [link for link in wheel_links if link.link.basename == "gamma"]
        asserts.equals(env, 1, len(direct_links))
        if len(direct_links) == 1:
            direct_target = [file for file in wheel_targets if file.basename == "_merge_wheel_direct.install"]
            asserts.equals(env, 1, len(direct_target))
            if len(direct_target) == 1:
                asserts.equals(env, direct_target[0], direct_links[0].install_tree)
            asserts.true(env, direct_links[0].link.is_symlink)
            asserts.true(env, direct_links[0].install_path.endswith("/site-packages/gamma"))
        sibling_links = [
            link
            for link in wheel_links
            if link.install_path.endswith("/site-packages/alpha/other")
        ]
        asserts.equals(env, 0, len(sibling_links))

        import_root_actions = [
            action
            for action in analysistest.target_actions(env)
            if any([
                output.basename == "_aspect_rules_py_imports.txt"
                for output in action.outputs.to_list()
            ])
        ]
        asserts.equals(env, 1, len(import_root_actions))
        if len(import_root_actions) == 1:
            manifest_roots = [
                line
                for line in import_root_actions[0].content.splitlines()
                if line.startswith("manifest-only:")
            ]
            asserts.equals(env, 1, len(manifest_roots))
            if len(manifest_roots) == 1:
                asserts.true(env, manifest_roots[0].endswith("/site-packages"))

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
        asserts.true(env, any([
            "_merge_wheel_extra.install" in arg
            for action in merge_actions
            for arg in action.argv
        ]))
        asserts.false(env, any([
            "_merge_wheel_legacy.install" in arg
            for action in merge_actions
            for arg in action.argv
        ]))

    return analysistest.end(env)

_merge_outputs_test = analysistest.make(
    _merge_outputs_test_impl,
    attrs = {
        "expected_metadata_links": attr.int(mandatory = True),
        "expected_wheel_aliases": attr.int(mandatory = True),
        "expected_wheel_links": attr.int(mandatory = True),
    },
)

def _exposed_layout_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, PyVenvLayoutInfo in target)
    if PyVenvLayoutInfo in target:
        layout = target[PyVenvLayoutInfo]
        asserts.equals(env, 5, len(layout.wheel_aliases.to_list()))
        asserts.equals(env, 3, len(layout.wheel_links.to_list()))
    return analysistest.end(env)

_exposed_layout_test = analysistest.make(_exposed_layout_test_impl)

def _native_sibling_layout_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    merge_actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "PySiteMerge"
    ]
    asserts.equals(env, 0, len(merge_actions))
    links = {
        link.install_path.rsplit("/site-packages/", 1)[-1]: link
        for link in target[PyVenvLayoutInfo].wheel_links.to_list()
    }
    asserts.true(env, "cv2" in links)
    if "cv2" in links:
        asserts.equals(env, "_native_wheel_headless.install", links["cv2"].install_tree.basename)
    asserts.true(env, "opencv_python.libs" in links)
    asserts.true(env, "opencv_python_headless.libs" in links)
    asserts.equals(env, {
        "shared/common.pyi": "_native_wheel_headless.install",
        "shared/from_full.pyi": "_native_wheel_full.install",
        "shared/from_headless.pyi": "_native_wheel_headless.install",
    }, {
        path: link.install_tree.basename
        for path, link in links.items()
        if path.startswith("shared/")
    })
    return analysistest.end(env)

_native_sibling_layout_test = analysistest.make(
    _native_sibling_layout_test_impl,
)

def _unknown_topology_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)
    asserts.false(env, any([
        action.mnemonic == "PySiteMerge"
        for action in actions
    ]))
    links = target[PyVenvLayoutInfo].wheel_links.to_list()
    asserts.false(env, any([
        link.link.basename == "shared"
        for link in links
    ]))
    pth_actions = [
        action
        for action in actions
        if any([
            output.basename == target.label.name + ".pth"
            for output in action.outputs.to_list()
        ])
    ]
    asserts.equals(env, 1, len(pth_actions))
    if len(pth_actions) == 1:
        asserts.true(env, "_unknown_topology_known.install" in pth_actions[0].content)
        asserts.true(env, "_unknown_topology_source.install" in pth_actions[0].content)
    return analysistest.end(env)

_unknown_topology_fallback_test = analysistest.make(
    _unknown_topology_fallback_test_impl,
)

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
    overlay_actions = [
        action
        for action in actions
        if any([output.basename.endswith("_venv.tar.gz") for output in action.outputs.to_list()])
    ]
    overlay_mtree_actions = [
        action
        for action in actions
        if any([output.basename.endswith("_venv.tar.gz.mtree") for output in action.outputs.to_list()])
    ]
    tar_actions = [
        action
        for action in actions
        if any([
            output.basename.endswith(".tar.gz") or output.basename.endswith(".tar.zst")
            for output in action.outputs.to_list()
        ])
    ]

    asserts.equals(env, 1, len(dependency_actions))
    asserts.equals(env, 1, len(source_actions))
    asserts.equals(env, 1, len(overlay_actions))
    asserts.equals(env, 1, len(overlay_mtree_actions))
    asserts.true(env, len(tar_actions) > 0)
    if len(dependency_actions) == 1 and len(source_actions) == 1 and len(overlay_actions) == 1:
        dependency_inputs = [file.path for file in dependency_actions[0].inputs.to_list()]
        source_inputs = [file.path for file in source_actions[0].inputs.to_list()]
        overlay_inputs = [file.path for file in overlay_actions[0].inputs.to_list()]
        merged_dependencies = [
            path
            for path in dependency_inputs
            if path.endswith("/site-packages/alpha") or path.endswith("/site-packages/beta")
        ]
        asserts.equals(env, 2, len(merged_dependencies))
        merged_dependency_paths = {path: True for path in merged_dependencies}
        asserts.false(env, any([path in merged_dependency_paths for path in source_inputs]))
        asserts.false(env, any(["/_wheels/" in path for path in source_inputs]))
        asserts.false(env, any([path.endswith("/site-packages/gamma") for path in source_inputs]))
        asserts.false(env, any([path.endswith(".install") for path in overlay_inputs]))
        asserts.false(env, any([path.endswith("/site-packages/gamma") for path in overlay_inputs]))
    if len(overlay_mtree_actions) == 1:
        link_lines = [
            line
            for line in overlay_mtree_actions[0].content.splitlines()
            if " type=link " in line
        ]
        asserts.equals(env, ctx.attr.expected_link_count, len(link_lines))
        asserts.true(env, any(["/site-packages/gamma " in line for line in link_lines]))
        asserts.false(env, any(["/site-packages/alpha/other " in line for line in link_lines]))

    return analysistest.end(env)

_merge_layer_outputs_test = analysistest.make(
    _merge_layer_outputs_test_impl,
    attrs = {"expected_link_count": attr.int(mandatory = True)},
)

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
        ":_merge_wheel_direct",
        ":_merge_wheel_grafts",
        ":_merge_wheel_extra",
        ":_merge_wheel_legacy",
        ":_merge_wheel_metadata_miss",
        ":_merge_wheel_regular",
    ]
    whl_install(
        name = "_merge_wheel_direct",
        directory_top_levels = ["direct-1.0.dist-info"],
        top_levels = [
            "direct-1.0.dist-info",
            "gamma",
        ],
        tags = ["manual"],
    )
    whl_install(
        name = "_merge_wheel_regular",
        directory_top_levels = ["alpha", "beta"],
        namespace_entries = ["alpha/left", "alpha/right", "beta/root"],
        namespace_top_levels = ["alpha", "beta"],
        regular_roots = ["alpha/left", "alpha/right", "beta/root"],
        top_levels = ["alpha", "beta"],
        tags = ["manual"],
    )
    whl_install(
        name = "_merge_wheel_grafts",
        directory_top_levels = ["alpha", "beta"],
        namespace_dirs = ["alpha/left", "alpha/right", "beta/root"],
        namespace_entries = ["alpha/left/graft", "alpha/right/graft", "beta/root/graft"],
        namespace_top_levels = ["alpha", "beta"],
        top_levels = ["alpha", "beta"],
        tags = ["manual"],
    )
    whl_install(
        name = "_merge_wheel_extra",
        directory_top_levels = ["alpha"],
        namespace_dirs = ["alpha/other"],
        namespace_entries = ["alpha/other"],
        namespace_top_levels = ["alpha"],
        top_levels = ["alpha"],
        tags = ["manual"],
    )
    whl_install(
        name = "_merge_wheel_legacy",
        directory_top_levels = ["alpha"],
        expose_install_tree = False,
        namespace_entries = ["alpha/legacy"],
        namespace_top_levels = ["alpha"],
        top_levels = ["alpha"],
        tags = ["manual"],
    )
    whl_install(
        name = "_merge_wheel_metadata_miss",
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
    py_binary(
        name = "_merge_outputs_exposed_binary",
        srcs = ["merge_outputs_test.py"],
        deps = merge_deps,
        expose_venv = True,
        tags = ["manual"],
    )
    py_image_layer(
        name = "_merge_outputs_layers",
        binary = ":_merge_outputs_binary",
        tags = ["manual"],
    )
    py_image_layer(
        name = "_merge_outputs_exposed_layers",
        binary = ":_merge_outputs_exposed_binary",
        tags = ["manual"],
    )
    _merge_outputs_test(
        name = "merge_outputs_test",
        expected_metadata_links = 0,
        expected_wheel_aliases = 0,
        expected_wheel_links = 1,
        target_under_test = ":_merge_outputs_binary",
    )
    _merge_outputs_test(
        name = "merge_outputs_venv_test",
        expected_metadata_links = 1,
        expected_wheel_aliases = 5,
        expected_wheel_links = 3,
        target_under_test = ":_merge_outputs_venv",
    )
    _exposed_layout_test(
        name = "exposed_layout_test",
        target_under_test = ":_merge_outputs_exposed_binary",
    )
    _merge_layer_outputs_test(
        name = "merge_layer_outputs_test",
        expected_link_count = 1,
        target_under_test = ":_merge_outputs_layers",
    )
    _merge_layer_outputs_test(
        name = "merge_exposed_layer_outputs_test",
        expected_link_count = 3,
        target_under_test = ":_merge_outputs_exposed_layers",
    )

    whl_install(
        name = "_native_wheel_full",
        directory_top_levels = [
            "cv2",
            "opencv_python.libs",
            "shared",
        ],
        namespace_entries = [
            "shared/common.pyi",
            "shared/from_full.pyi",
        ],
        namespace_top_levels = ["shared"],
        top_levels = [
            "cv2",
            "opencv_python.libs",
            "shared",
        ],
        tags = ["manual"],
    )
    whl_install(
        name = "_native_wheel_headless",
        directory_top_levels = [
            "cv2",
            "opencv_python_headless.libs",
            "shared",
        ],
        namespace_entries = [
            "shared/common.pyi",
            "shared/from_headless.pyi",
        ],
        namespace_top_levels = ["shared"],
        top_levels = [
            "cv2",
            "opencv_python_headless.libs",
            "shared",
        ],
        tags = ["manual"],
    )
    py_binary(
        name = "_native_sibling_binary",
        srcs = ["merge_outputs_test.py"],
        deps = [":_native_wheel_full", ":_native_wheel_headless"],
        tags = ["manual"],
    )
    _native_sibling_layout_test(
        name = "native_sibling_layout_test",
        target_under_test = ":_native_sibling_binary",
    )

    whl_install(
        name = "_unknown_topology_known",
        directory_top_levels = ["shared"],
        namespace_entries = ["shared/known"],
        namespace_top_levels = ["shared"],
        top_levels = ["shared"],
        tags = ["manual"],
    )
    whl_install(
        name = "_unknown_topology_source",
        directory_top_levels = ["shared"],
        top_levels = ["shared"],
        topology_known = False,
        tags = ["manual"],
    )
    py_binary(
        name = "_unknown_topology_binary",
        srcs = ["merge_outputs_test.py"],
        deps = [
            ":_unknown_topology_known",
            ":_unknown_topology_source",
        ],
        tags = ["manual"],
    )
    _unknown_topology_fallback_test(
        name = "unknown_topology_fallback_test",
        target_under_test = ":_unknown_topology_binary",
    )

    whl_install(
        name = "_missing_tree_regular",
        directory_top_levels = ["conflict"],
        expose_install_tree = False,
        namespace_entries = ["conflict/root"],
        namespace_top_levels = ["conflict"],
        regular_roots = ["conflict/root"],
        top_levels = ["conflict"],
        tags = ["manual"],
    )
    whl_install(
        name = "_missing_tree_graft",
        directory_top_levels = ["conflict"],
        namespace_dirs = ["conflict/root"],
        namespace_entries = ["conflict/root/graft"],
        namespace_top_levels = ["conflict"],
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
