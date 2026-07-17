"""Analysis checks for private venv site-packages symlink batching."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _custom_symlink_tool_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    data = ctx.actions.declare_file(ctx.label.name + ".data")
    ctx.actions.write(executable, "#!/usr/bin/env bash\nexit 0\n", is_executable = True)
    ctx.actions.write(data, "custom tool runfile\n")
    return [DefaultInfo(executable = executable, runfiles = ctx.runfiles(files = [data]))]

custom_symlink_tool = rule(implementation = _custom_symlink_tool_impl, executable = True)

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

def _custom_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    symlink_actions = [action for action in actions if action.mnemonic == "PyVenvSymlinks"]
    asserts.equals(env, 1, len(symlink_actions))
    inputs = [file.short_path for file in symlink_actions[0].inputs.to_list()]
    asserts.true(env, any([path.endswith("/_custom_symlink_tool.sh") for path in inputs]))
    asserts.true(env, any(["custom" in path and "symlink" in path and path.endswith("runfiles") for path in inputs]))
    return analysistest.end(env)

def _windows_exec_private_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_fallback(env, analysistest.target_actions(env), "._test.venv", 2)
    return analysistest.end(env)

def _windows_target_private_impl(ctx):
    env = analysistest.begin(ctx)
    outputs = _outputs(analysistest.target_actions(env), "PyVenvSymlinks")
    asserts.equals(env, 2, len(outputs))
    asserts.true(env, all(["/._test.venv/lib/" in path for path in outputs]))
    return analysistest.end(env)

def _no_symlink_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_fallback(env, analysistest.target_actions(env), "._test.venv", 2)
    return analysistest.end(env)

private_venv_symlinks_test = analysistest.make(_private_impl)
exposed_venv_symlinks_test = analysistest.make(_exposed_impl)
explicit_venv_symlinks_test = analysistest.make(_explicit_impl)
custom_venv_symlinks_test = analysistest.make(
    _custom_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": [str(Label(":_custom_symlink_toolchain"))],
    },
)
windows_exec_private_venv_symlinks_test = analysistest.make(
    _windows_exec_private_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label(":_linux_x86_64_windows_exec")),
    },
)
windows_target_private_venv_symlinks_test = analysistest.make(
    _windows_target_private_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label(":_windows_x86_64")),
    },
)
no_symlink_venv_symlinks_test = analysistest.make(
    _no_symlink_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": [str(Label(":_no_symlink_toolchain"))],
    },
)
