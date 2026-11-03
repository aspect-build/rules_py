"""Analysis-time test: a launcher built for Windows is named `<name>.exe`.

Windows finds and starts programs by their extension, so an extensionless
launcher can't be started by name or by most process APIs there.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _windows_executable_name_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        target.label.name + ".exe",
        target[DefaultInfo].files_to_run.executable.basename,
    )
    return analysistest.end(env)

windows_executable_name_test = analysistest.make(
    _windows_executable_name_test_impl,
    config_settings = {
        "//command_line_option:platforms": [
            str(Label("//py/tests/py-venv-multi-exec:windows_x86_64")),
        ],
    },
)
