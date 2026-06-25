"""Repository rules for Python interpreter toolchains."""

load("@bazel_features//:features.bzl", features = "bazel_features")
load(":exclude_feature.bzl", "INTERPRETER_FEATURES")

_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_FREETHREADING_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"
_EXCLUDE_FEATURE_FLAG = "@aspect_rules_py//py/private/interpreter:exclude_feature"

def _python_interpreter_impl(rctx):
    """Downloads and extracts a Python interpreter from PBS."""
    url = rctx.attr.url
    platform = rctx.attr.platform

    python_version = rctx.attr.python_version
    sha256 = rctx.attr.sha256
    strip_prefix = rctx.attr.strip_prefix
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

    # Delete terminfo symlink loops on newer PBS releases (linux only)
    if "linux" in platform:
        rctx.delete("share/terminfo")

    rctx.file("BUILD.bazel", content = _build_file_content(
        major = major,
        minor = minor,
        micro = micro,
        python_bin = python_bin,
        is_windows = is_windows,
    ))

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return rctx.repo_metadata(reproducible = True)

def _feature_filegroups(major, minor, is_windows):
    """Generate per-feature filegroup targets and config_settings.

    Returns a tuple of (feature_targets_str, all_feature_exclude_patterns).
    The exclude patterns are used to carve out feature files from the core filegroup.
    """
    if is_windows:
        return "", []

    lines = []
    all_excludes = []

    for feature_name, feature_info in INTERPRETER_FEATURES.items():
        patterns = [
            p.format(major = major, minor = minor)
            for p in feature_info["include"]
        ]
        all_excludes.extend(patterns)

        lines.append("""\
config_setting(
    name = "_exclude_{feature}",
    flag_values = {{"{flag}": "{feature}"}},
)
""".format(feature = feature_name, flag = _EXCLUDE_FEATURE_FLAG))

        lines.append("""\
filegroup(
    name = "_feature_{feature}",
    srcs = glob({patterns}, allow_empty = True),
)
""".format(feature = feature_name, patterns = repr(patterns)))

    return "\n".join(lines), all_excludes

def _build_file_content(major, minor, micro, python_bin, is_windows):
    """Generate the full BUILD.bazel content for an interpreter repo."""

    feature_targets, feature_excludes = _feature_filegroups(major, minor, is_windows)

    if is_windows:
        core_include = '["**/*.py", "**/*.pyd", "**/*.dll", "**/*.exe", "include/**", "Lib/**"]'
        core_exclude = '["Lib/**/test/**", "Lib/**/tests/**", "**/__pycache__/*.pyc*"]'
    else:
        core_include = '["bin/**", "lib/**"]'
        core_exclude = repr(
            [
                "lib/**/*.a",
                "lib/python{}.{}/**/test/**".format(major, minor),
                "lib/python{}.{}/**/tests/**".format(major, minor),
                "**/__pycache__/*.pyc*",
            ] +
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
load("@rules_python//python:py_exec_tools_toolchain.bzl", "py_exec_tools_toolchain")

package(default_visibility = ["//visibility:public"])

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

py_exec_tools_toolchain(
    name = "exec_tools_toolchain",
)
""".format(
        python_bin = python_bin,
        major = major,
        minor = minor,
        micro = micro,
        feature_targets = feature_targets,
        feature_selects = feature_selects,
        core_include = core_include,
        core_exclude = core_exclude,
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

def _platform_setting_name(flag, value):
    """Generate a unique config_setting name for a flag/value pair."""

    # Extract the last path component of the flag label as a readable prefix,
    # e.g. "@aspect_rules_py//uv/private/constraints/platform:platform_libc"
    # -> "platform_libc_glibc"
    name = flag.split(":")[-1] if ":" in flag else flag.split("/")[-1]
    return "{}_is_{}".format(name, value)

def _version_setting_name(major_minor):
    """Generate config_setting name for a Python version."""
    return "python_version_is_" + major_minor.replace(".", "_")

def _freethreaded_setting_name(value):
    """Generate config_setting name for the freethreaded flag."""
    return "freethreaded_is_" + ("true" if value else "false")

def _python_toolchains_impl(rctx):
    """Creates toolchain() registrations pointing to interpreter repos."""
    content = [
        'load("@bazel_skylib//lib:selects.bzl", "selects")',
        'load("@aspect_rules_py//py/private/interpreter:current_py_toolchain.bzl", "current_py_toolchain")',
        'package(default_visibility = ["//visibility:public"])',
    ]

    # First pass: collect all unique flag/value pairs and version/freethreaded
    # combos so we generate each config_setting exactly once.
    seen_settings = {}  # name -> (flag, value)
    seen_versions = {}  # major_minor -> True
    seen_freethreaded = {}  # bool -> True
    toolchain_infos = []

    for entry in rctx.attr.toolchains:
        info = json.decode(entry)
        platform_settings = info.get("platform_target_settings", {})
        setting_names = []
        for flag, value in platform_settings.items():
            name = _platform_setting_name(flag, value)
            if name not in seen_settings:
                seen_settings[name] = (flag, value)
            setting_names.append(name)

        # Track version/freethreaded for hub-local config_settings
        python_version = info["python_version"]
        seen_versions[python_version] = True
        seen_freethreaded[info.get("freethreaded", False)] = True

        toolchain_infos.append((info, setting_names))

    # Emit hub-local version config_settings so toolchain resolution doesn't
    # need to fetch individual interpreter repos.
    for major_minor in seen_versions.keys():
        group_name = _version_setting_name(major_minor)
        content.append("""
config_setting(
    name = "_{group}_our_major_minor",
    flag_values = {{"{our_flag}": "{major_minor}"}},
)

config_setting(
    name = "_{group}_rpy_major_minor",
    flag_values = {{"{rpy_flag}": "{major_minor}"}},
)

selects.config_setting_group(
    name = "{group}",
    match_any = [
        ":_{group}_our_major_minor",
        ":_{group}_rpy_major_minor",
    ],
)
""".format(
            group = group_name,
            major_minor = major_minor,
            our_flag = _PYTHON_VERSION_FLAG,
            rpy_flag = _RPY_VERSION_FLAG,
        ))

    # Emit hub-local freethreaded config_settings
    for value in seen_freethreaded.keys():
        name = _freethreaded_setting_name(value)
        content.append("""
config_setting(
    name = "{name}",
    flag_values = {{"{flag}": "{value}"}},
)
""".format(
            name = name,
            flag = _FREETHREADING_FLAG,
            value = "true" if value else "false",
        ))

    # Emit config_settings for platform target settings
    for name, (flag, value) in seen_settings.items():
        content.append("""
config_setting(
    name = "{name}",
    flag_values = {{"{flag}": "{value}"}},
)
""".format(name = name, flag = flag, value = value))

    # Second pass: emit toolchain() registrations
    for info, platform_setting_names in toolchain_infos:
        extra_config_settings = info.get("config_settings", [])
        extra_target_compatible = info.get("target_compatible_with", [])
        extra_exec_compatible = info.get("exec_compatible_with", [])

        version_setting = ":" + _version_setting_name(info["python_version"])
        freethreaded_setting = ":" + _freethreaded_setting_name(info.get("freethreaded", False))

        target_settings = [
            version_setting,
            freethreaded_setting,
        ] + [":" + name for name in platform_setting_names] + extra_config_settings

        target_compatible_with = info["compatible_with"] + extra_target_compatible
        exec_compatible_with = info["compatible_with"] + extra_exec_compatible

        content.append("""
# The Python interpreter toolchain has no exec_compatible_with: the interpreter
# runs on the TARGET platform (inside the virtualenv), not on the exec host.
# Setting exec_compatible_with = platform_constraints would prevent this
# toolchain from being selected during cross-compilation (e.g. building an
# arm64 image on an amd64 host), because the exec platform (amd64) would not
# satisfy the arm64 exec constraint.  The target_compatible_with constraint is
# sufficient to pick the right interpreter for the target.
toolchain(
    name = "{name}",
    target_compatible_with = {target_compatible_with},
    target_settings = {target_settings},
    toolchain = "@{repo}//:runtime_pair",
    toolchain_type = "@bazel_tools//tools/python:toolchain_type",
)
""".format(
            name = info["name"],
            repo = info["repo"],
            target_compatible_with = target_compatible_with,
            target_settings = target_settings,
        ))

        if info["register_exec_tools"]:
            content.append("""# Exec tools toolchain: selected by exec platform (not target platform) so
# that build actions using the interpreter (e.g. compileall) get a runnable
# binary on the build host regardless of the target platform being built for.
toolchain(
    name = "{name}_exec_tools",
    exec_compatible_with = {exec_compatible_with},
    toolchain = "@{repo}//:exec_tools_toolchain",
    toolchain_type = "@rules_python//python:exec_tools_toolchain_type",
)
""".format(
                name = info["name"],
                repo = info["repo"],
                exec_compatible_with = exec_compatible_with,
            ))

    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)

current_py_toolchain(
    name = "current_py_toolchain",
)
""")

    rctx.file("BUILD.bazel", content = "\n".join(content))

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return rctx.repo_metadata(reproducible = True)

python_toolchains = repository_rule(
    implementation = _python_toolchains_impl,
    attrs = {
        "toolchains": attr.string_list(),
    },
)
