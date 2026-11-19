"""The Python version flag and the baselines terminals capture from it."""

load("@aspect_rules_py_config//:config.bzl", "PYTHON_VERSION_SCOPE")
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")

# buildifier: disable=unnamed-macro
def python_version_flags():
    """Declares the version flags, or aliases them under project scope."""
    if PYTHON_VERSION_SCOPE == "project":
        # Bazel finds a scoped flag's project from the flag's package, so the
        # project-scoped flags live in the config repository, which ships the
        # PROJECT.scl that forwards to the root module's definition. The
        # baselines share the scope, or targets outside the project would
        # split on them alone.
        native.alias(
            name = "python_version",
            actual = "@aspect_rules_py_config//:python_version",
        )
        for name in ["baseline_python_version", "baseline_rules_python_version"]:
            native.alias(
                name = name,
                actual = "@aspect_rules_py_config//:" + name,
                visibility = ["//py:__subpackages__"],
            )
        return

    string_flag(
        name = "python_version",
        build_setting_default = "",
        scope = PYTHON_VERSION_SCOPE or None,
    )

    # Internal transition scratch state. Python terminals capture the version
    # settings they inherited before applying their own python_version attr,
    # then data edges use them to return runtime files to the caller's
    # configuration.
    string_flag(
        name = "baseline_python_version",
        build_setting_default = "<unset>",
        visibility = ["//py:__subpackages__"],
    )

    string_flag(
        name = "baseline_rules_python_version",
        build_setting_default = "<unset>",
        visibility = ["//py:__subpackages__"],
    )
