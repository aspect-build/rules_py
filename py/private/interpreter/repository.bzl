"""Repository rules for downloading Python interpreters from python-build-standalone."""

load(":exclude_feature.bzl", "INTERPRETER_FEATURES")

_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_FREETHREADING_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"
_EXCLUDE_FEATURE_FLAG = "@aspect_rules_py//py/private/interpreter:exclude_feature"

# BUILD file for version/platform combinations that don't exist in any release.
# Uses sentinel values that will never match, so toolchain resolution skips them.
_UNAVAILABLE_BUILD = """\
load("@bazel_skylib//lib:selects.bzl", "selects")

package(default_visibility = ["//visibility:public"])

config_setting(
    name = "_is_our_major_minor",
    flag_values = {{"{our_flag}": "__unavailable__"}},
)

config_setting(
    name = "_is_our_major_minor_micro",
    flag_values = {{"{our_flag}": "__unavailable__"}},
)

config_setting(
    name = "_is_rpy_major_minor",
    flag_values = {{"{rpy_flag}": "__unavailable__"}},
)

config_setting(
    name = "_is_rpy_major_minor_micro",
    flag_values = {{"{rpy_flag}": "__unavailable__"}},
)

selects.config_setting_group(
    name = "is_matching_python_version",
    match_any = [
        ":_is_our_major_minor",
        ":_is_our_major_minor_micro",
        ":_is_rpy_major_minor",
        ":_is_rpy_major_minor_micro",
    ],
)

# Freethreaded matching: use "true" so combined with the version sentinel
# this toolchain is never selected.
config_setting(
    name = "is_matching_freethreaded",
    flag_values = {{"{freethreading_flag}": "true"}},
)
"""

def _python_interpreter_impl(rctx):
    """Downloads and extracts a Python interpreter from PBS."""
    url = rctx.attr.url
    platform = rctx.attr.platform

    if not url:
        # Unavailable version/platform combination — generate stub BUILD
        rctx.file("BUILD.bazel", content = _UNAVAILABLE_BUILD.format(
            our_flag = _PYTHON_VERSION_FLAG,
            rpy_flag = _RPY_VERSION_FLAG,
            freethreading_flag = _FREETHREADING_FLAG,
        ))
        return

    python_version = rctx.attr.python_version
    sha256 = rctx.attr.sha256
    strip_prefix = rctx.attr.strip_prefix
    is_freethreaded = rctx.attr.freethreaded

    rctx.download_and_extract(
        url = [url],
        sha256 = sha256,
        stripPrefix = strip_prefix,
    )

    # Determine the Python binary path
    is_windows = "windows" in platform
    python_bin = "python.exe" if is_windows else "bin/python3"
    version_parts = python_version.split(".")
    major = version_parts[0]
    minor = version_parts[1]
    micro = version_parts[2] if len(version_parts) > 2 else "0"
    major_minor = "{}.{}".format(major, minor)

    # Delete terminfo symlink loops on newer PBS releases (linux only)
    if "linux" in platform:
        rctx.delete("share/terminfo")

    # Generate the BUILD file
    is_windows = "windows" in platform

    rctx.file("BUILD.bazel", content = _build_file_content(
        major = major,
        minor = minor,
        micro = micro,
        major_minor = major_minor,
        python_version = python_version,
        python_bin = "python.exe" if is_windows else "bin/python3",
        is_windows = is_windows,
        is_freethreaded = is_freethreaded,
    ))

def _feature_filegroups(major, minor, is_windows):
    """Generate per-feature filegroup targets and config_settings.

    Returns a tuple of (feature_targets_str, all_feature_exclude_patterns).
    The exclude patterns are used to carve out feature files from the core filegroup.
    """
    if is_windows:
        # Feature exclusions not yet supported on Windows
        return "", []

    lines = []
    all_excludes = []

    for feature_name, feature_info in INTERPRETER_FEATURES.items():
        patterns = [
            p.format(major = major, minor = minor)
            for p in feature_info["include"]
        ]
        all_excludes.extend(patterns)

        # config_setting that matches when this feature IS excluded
        lines.append("""\
config_setting(
    name = "_exclude_{feature}",
    flag_values = {{"{flag}": "{feature}"}},
)
""".format(feature = feature_name, flag = _EXCLUDE_FEATURE_FLAG))

        # filegroup for this feature's files
        lines.append("""\
filegroup(
    name = "_feature_{feature}",
    srcs = glob({patterns}),
)
""".format(feature = feature_name, patterns = repr(patterns)))

    return "\n".join(lines), all_excludes

def _build_file_content(major, minor, micro, major_minor, python_version, python_bin, is_windows, is_freethreaded):
    """Generate the full BUILD.bazel content for an interpreter repo."""

    feature_targets, feature_excludes = _feature_filegroups(major, minor, is_windows)

    if is_windows:
        core_include = '["**/*.py", "**/*.pyd", "**/*.dll", "**/*.exe", "include/**", "Lib/**"]'
        core_exclude = '["Lib/**/test/**", "Lib/**/tests/**", "**/__pycache__/*.pyc*"]'
    else:
        core_include = '["bin/**", "lib/**"]'
        core_exclude = repr(
            ["lib/**/*.a",
             "lib/python{}.{}/**/test/**".format(major, minor),
             "lib/python{}.{}/**/tests/**".format(major, minor),
             "**/__pycache__/*.pyc*"] +
            feature_excludes,
        )

    # Build the select() expressions for optional features
    feature_selects = ""
    if not is_windows:
        for feature_name in INTERPRETER_FEATURES.keys():
            feature_selects += """\
    + select({{
        ":_exclude_{feature}": [],
        "//conditions:default": [":_feature_{feature}"],
    }})
""".format(feature = feature_name)

    return """\
load("@rules_python//python:py_runtime.bzl", "py_runtime")
load("@rules_python//python:py_runtime_pair.bzl", "py_runtime_pair")
load("@bazel_skylib//lib:selects.bzl", "selects")

package(default_visibility = ["//visibility:public"])

config_setting(
    name = "_is_our_major_minor",
    flag_values = {{
        "{our_flag}": "{major_minor}",
    }},
)

config_setting(
    name = "_is_our_major_minor_micro",
    flag_values = {{
        "{our_flag}": "{version}",
    }},
)

config_setting(
    name = "_is_rpy_major_minor",
    flag_values = {{
        "{rpy_flag}": "{major_minor}",
    }},
)

config_setting(
    name = "_is_rpy_major_minor_micro",
    flag_values = {{
        "{rpy_flag}": "{version}",
    }},
)

selects.config_setting_group(
    name = "is_matching_python_version",
    match_any = [
        ":_is_our_major_minor",
        ":_is_our_major_minor_micro",
        ":_is_rpy_major_minor",
        ":_is_rpy_major_minor_micro",
    ],
)

{freethreaded_config_setting}

# --- Optional interpreter features ---

{feature_targets}

# --- Core + optional filegroups ---

filegroup(
    name = "_core",
    srcs = glob(
        include = {core_include},
        exclude = {core_exclude},
    ),
)

filegroup(
    name = "files",
    srcs = [":_core"]
{feature_selects}    ,
)

py_runtime(
    name = "py3_runtime",
    files = [":files"],
    interpreter = "{python_bin}",
    interpreter_version_info = {{
        "major": "{major}",
        "minor": "{minor}",
        "micro": "{micro}",
    }},
    python_version = "PY3",
)

py_runtime_pair(
    name = "runtime_pair",
    py2_runtime = None,
    py3_runtime = ":py3_runtime",
)
""".format(
        our_flag = _PYTHON_VERSION_FLAG,
        rpy_flag = _RPY_VERSION_FLAG,
        version = python_version,
        major_minor = major_minor,
        python_bin = python_bin,
        major = major,
        minor = minor,
        micro = micro,
        freethreaded_config_setting = _freethreaded_config_setting(is_freethreaded),
        feature_targets = feature_targets,
        feature_selects = feature_selects,
        core_include = core_include,
        core_exclude = core_exclude,
    )

def _freethreaded_config_setting(is_freethreaded):
    """Generate config_setting for the freethreaded flag."""
    return """\
config_setting(
    name = "is_matching_freethreaded",
    flag_values = {{
        "{flag}": "{value}",
    }},
)
""".format(
        flag = _FREETHREADING_FLAG,
        value = "true" if is_freethreaded else "false",
    )

python_interpreter = repository_rule(
    implementation = _python_interpreter_impl,
    attrs = {
        "freethreaded": attr.bool(default = False),
        "platform": attr.string(mandatory = True),
        "python_version": attr.string(default = ""),
        "sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = "python"),
        "url": attr.string(default = ""),
    },
)

def _python_toolchains_impl(rctx):
    """Creates toolchain() registrations pointing to interpreter repos."""
    content = ['package(default_visibility = ["//visibility:public"])']

    for entry in rctx.attr.toolchains:
        info = json.decode(entry)

        target_settings = [
            "@{repo}//:is_matching_python_version".format(repo = info["repo"]),
            "@{repo}//:is_matching_freethreaded".format(repo = info["repo"]),
        ]

        content.append("""
toolchain(
    name = "{name}",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {compatible_with},
    target_settings = {target_settings},
    toolchain = "@{repo}//:runtime_pair",
    toolchain_type = "@bazel_tools//tools/python:toolchain_type",
)
""".format(
            name = info["name"],
            repo = info["repo"],
            compatible_with = info["compatible_with"],
            target_settings = target_settings,
        ))

    rctx.file("BUILD.bazel", content = "\n".join(content))

python_toolchains = repository_rule(
    implementation = _python_toolchains_impl,
    attrs = {
        "toolchains": attr.string_list(),
    },
)
