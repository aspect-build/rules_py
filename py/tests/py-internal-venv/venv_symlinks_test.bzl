"""Analysis checks for private venv site-packages symlink batching."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:providers.bzl", "PyWheelsInfo", "make_wheel_record")
load("//py/private:py_info.bzl", "PyInfo")

def _no_runtime_toolchain_impl(_ctx):
    return [platform_common.ToolchainInfo(exec_tools = struct(exec_runtime = None))]

no_runtime_toolchain = rule(implementation = _no_runtime_toolchain_impl)

def _no_runtime_wheel_impl(ctx):
    tree = ctx.actions.declare_directory(ctx.label.name + ".install")
    site_packages = "/".join([
        ctx.workspace_name,
        ctx.label.package,
        tree.basename,
        "lib/python3.9/site-packages",
    ])
    ctx.actions.run_shell(
        outputs = [tree],
        command = "mkdir -p \"$1/lib/python3.9/site-packages/example\" && touch \"$1/lib/python3.9/site-packages/example/__init__.py\"",
        arguments = [tree.path],
    )
    wheel = make_wheel_record(
        top_levels = ("example",),
        site_packages_rfpath = site_packages,
        install_tree = tree,
    )
    return [
        DefaultInfo(files = depset([tree]), runfiles = ctx.runfiles(files = [tree])),
        PyInfo(imports = depset([site_packages]), transitive_sources = depset([tree])),
        PyWheelsInfo(wheels = depset([wheel])),
    ]

no_runtime_wheel = rule(implementation = _no_runtime_wheel_impl)

def _outputs(actions, mnemonic):
    return [
        output.short_path
        for action in actions
        if action.mnemonic == mnemonic
        for output in action.outputs.to_list()
    ]

def _assert_fallback(env, actions, venv_name, expected_links):
    asserts.equals(env, [], _outputs(actions, "PyVenvSymlinks"))
    links = _outputs(actions, "UnresolvedSymlink")
    prefix = "py/tests/py-internal-venv/{}/lib/".format(venv_name)
    asserts.equals(env, expected_links, len([path for path in links if path.startswith(prefix)]))

def _private_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    symlink_actions = [action for action in actions if action.mnemonic == "PyVenvSymlinks"]
    asserts.equals(env, 1, len(symlink_actions))
    outputs = _outputs(symlink_actions, "PyVenvSymlinks")
    asserts.equals(env, 2, len(outputs))
    asserts.true(env, all(["/._test.venv/lib/" in path for path in outputs]))
    asserts.true(
        env,
        any([path.endswith("/._test.venv/bin/cowsay") for path in _outputs(actions, "TemplateExpand")]),
        "console scripts should keep their TemplateExpand actions",
    )
    return analysistest.end(env)

def _exposed_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_fallback(env, analysistest.target_actions(env), "._exposed_test.venv", 2)
    return analysistest.end(env)

def _explicit_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_fallback(env, analysistest.target_actions(env), "._explicit_venv", 2)
    return analysistest.end(env)

def _windows_private_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_fallback(env, analysistest.target_actions(env), "._test.venv", 2)
    return analysistest.end(env)

def _no_runtime_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_fallback(env, analysistest.target_actions(env), ".__no_runtime_test.venv", 1)
    return analysistest.end(env)

private_venv_symlinks_test = analysistest.make(_private_impl)
exposed_venv_symlinks_test = analysistest.make(_exposed_impl)
explicit_venv_symlinks_test = analysistest.make(_explicit_impl)
windows_private_venv_symlinks_test = analysistest.make(
    _windows_private_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label(":_windows_x86_64")),
    },
)
no_runtime_venv_symlinks_test = analysistest.make(
    _no_runtime_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": [str(Label(":_no_runtime_toolchain"))],
    },
)
