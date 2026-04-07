# Analysis test: whl_install must provide OutputGroupInfo with install_dir.
#
# Since #907 removed install_dir from DefaultInfo.files, the install_dir output
# group is the supported way for consumers to access the wheel directory directly
# (e.g. to extract a non-console-script binary via a genrule).

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _whl_install_output_group_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # DefaultInfo.files must be empty — whl_install was intentionally changed
    # in #907 to not include install_dir there.
    default_files = target[DefaultInfo].files.to_list()
    asserts.equals(env, [], default_files)

    # OutputGroupInfo must expose install_dir with exactly one TreeArtifact
    # named "install".
    asserts.true(
        env,
        OutputGroupInfo in target,
        "whl_install must provide OutputGroupInfo",
    )
    install_dir_files = target[OutputGroupInfo].install_dir.to_list()
    asserts.equals(env, 1, len(install_dir_files))
    asserts.equals(env, "install", install_dir_files[0].basename)

    return analysistest.end(env)

_whl_install_output_group_test = analysistest.make(
    _whl_install_output_group_impl,
    # The hub alias for @pypi//iniconfig uses target_compatible_with = incompatible
    # by default; set the venv flag so the select resolves to the whl_install target.
    config_settings = {
        # str(Label(...)) produces the canonical @@repo+//... form, which is
        # repo-context-independent and satisfies analysis_test_transition's
        # requirement for string keys.
        str(Label("@aspect_rules_py//uv/private/constraints/venv:venv")): "uv-whl-install-output-group",
    },
)

def whl_install_output_group_test_suite():
    _whl_install_output_group_test(
        name = "whl_install_output_group_test",
        target_under_test = "@pypi//iniconfig",
    )
