"""Repository rules for downloading Python interpreters from python-build-standalone."""

_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_FREETHREADING_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"

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

    # Windows and Unix have different directory layouts
    if is_windows:
        files_glob_include = '["**/*.py", "**/*.pyd", "**/*.dll", "**/*.exe", "include/**", "Lib/**"]'
        files_glob_exclude = '["Lib/**/test/**", "Lib/**/tests/**", "**/__pycache__/*.pyc*"]'
    else:
        files_glob_include = '["bin/**", "include/**", "lib/**", "share/**"]'
        files_glob_exclude = '["lib/**/*.a", "lib/python{major}.{minor}/**/test/**", "lib/python{major}.{minor}/**/tests/**", "**/__pycache__/*.pyc*"]'.format(
            major = major,
            minor = minor,
        )

    rctx.file("BUILD.bazel", content = """\
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

filegroup(
    name = "files",
    srcs = glob(
        include = {files_glob_include},
        exclude = {files_glob_exclude},
    ),
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
        files_glob_include = files_glob_include,
        files_glob_exclude = files_glob_exclude,
    ))

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
