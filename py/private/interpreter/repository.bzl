"""Repository rules for Python interpreter toolchains."""

load("@bazel_features//:features.bzl", features = "bazel_features")
load(":exclude_feature.bzl", "INTERPRETER_FEATURES")

_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_FREETHREADING_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"
_EXCLUDE_FEATURE_FLAG = "@aspect_rules_py//py/private/interpreter:exclude_feature"

# CPython through 3.13 defines the bytecode magic in the frozen importlib
# source. Python 3.14 moved its authoritative value to an internal header:
# https://github.com/python/cpython/blob/v3.13.2/Lib/importlib/_bootstrap_external.py
# https://github.com/python/cpython/blob/v3.14.0/Include/internal/pycore_magic_number.h
def _parse_pyc_magic_number(content, source_kind, description):
    matches = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if source_kind == "header":
            tokens = [
                token
                for token in line.replace("\t", " ").split(" ")
                if token
            ]
            if tokens[:2] == ["#define", "PYC_MAGIC_NUMBER"]:
                if len(tokens) < 3:
                    fail("{} has a malformed definition: {}".format(description, repr(raw_line)))
                matches.append((tokens[2], raw_line))
        else:
            source_prefix = "MAGIC_NUMBER = ("
            if line.startswith(source_prefix):
                value = line[len(source_prefix):]
                if ")" not in value:
                    fail("{} has a malformed assignment: {}".format(description, repr(raw_line)))
                matches.append((value.split(")")[0], raw_line))

    if len(matches) != 1:
        fail("{} must contain exactly one PYC_MAGIC_NUMBER, found {}".format(
            description,
            len(matches),
        ))

    value, raw_line = matches[0]
    if not value or not all([char in "0123456789" for char in value.elems()]):
        fail("{} has a non-decimal value: {}".format(description, repr(raw_line)))

    magic_number = int(value)
    if magic_number > 0xffff:
        fail("{} has a value outside the 16-bit range: {}".format(description, magic_number))
    return magic_number

def _read_pyc_magic_number(rctx, major, minor, is_windows):
    abi_suffix = "t" if rctx.attr.freethreaded else ""
    version = "{}.{}{}".format(major, minor, abi_suffix)
    if is_windows:
        paths = [
            "include/internal/pycore_magic_number.h",
            "Lib/importlib/_bootstrap_external.py",
        ]
    else:
        paths = [
            "include/python{}/internal/pycore_magic_number.h".format(version),
            "lib/python{}/importlib/_bootstrap_external.py".format(version),
        ]

    mode = "free-threaded" if rctx.attr.freethreaded else "regular"
    description = "PBS Python {} for {} ({})".format(
        rctx.attr.python_version,
        rctx.attr.platform,
        mode,
    )
    for path, source_kind in [(paths[0], "header"), (paths[1], "source")]:
        if rctx.path(path).exists:
            return _parse_pyc_magic_number(
                rctx.read(path),
                source_kind,
                "{} {}".format(description, path),
            )

    fail("{} contains neither {} nor {}".format(description, paths[0], paths[1]))

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
    releaselevel = "final"
    serial = "0"
    for marker, level in [("rc", "candidate"), ("b", "beta"), ("a", "alpha")]:
        marker_index = micro.find(marker)
        if marker_index >= 0:
            serial = micro[marker_index + len(marker):] or "0"
            micro = micro[:marker_index] or "0"
            releaselevel = level
            break
    pyc_magic_number = _read_pyc_magic_number(rctx, major, minor, is_windows)

    # Delete terminfo symlink loops on newer PBS releases (linux only)
    if "linux" in platform:
        rctx.delete("share/terminfo")

    rctx.file("BUILD.bazel", content = _build_file_content(
        abi_flags = rctx.attr.abi_flags,
        major = major,
        minor = minor,
        micro = micro,
        python_bin = python_bin,
        pyc_magic_number = pyc_magic_number,
        is_windows = is_windows,
        releaselevel = releaselevel,
        serial = serial,
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

def _build_file_content(major, minor, micro, python_bin, pyc_magic_number, is_windows, abi_flags, releaselevel, serial):
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
load("@aspect_rules_py//py/private/interpreter:interpreter_executable.bzl", "interpreter_executable")
load("@rules_python//python:py_runtime.bzl", "py_runtime")
load("@rules_python//python:py_exec_tools_toolchain.bzl", "py_exec_tools_toolchain")
load("@aspect_rules_py//py/private/interpreter:pbs_runtime_pair.bzl", "pbs_runtime_pair")

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
    abi_flags = "{abi_flags}",
    files = [":files"],
    interpreter = "{python_bin}",
    interpreter_version_info = {{
        "major": "{major}",
        "minor": "{minor}",
        "micro": "{micro}",
        "releaselevel": "{releaselevel}",
        "serial": "{serial}",
    }},
    python_version = "PY3",
)

pbs_runtime_pair(
    name = "runtime_pair",
    pyc_magic_number = {pyc_magic_number},
    py3_runtime = ":py3_runtime",
)

interpreter_executable(
    name = "exec_interpreter",
    runtime_pair = ":runtime_pair",
)

py_exec_tools_toolchain(
    name = "exec_tools_toolchain",
    exec_interpreter = ":exec_interpreter",
)
""".format(
        abi_flags = abi_flags,
        python_bin = python_bin,
        major = major,
        minor = minor,
        micro = micro,
        releaselevel = releaselevel,
        serial = serial,
        pyc_magic_number = pyc_magic_number,
        feature_targets = feature_targets,
        feature_selects = feature_selects,
        core_include = core_include,
        core_exclude = core_exclude,
    )

python_interpreter = repository_rule(
    implementation = _python_interpreter_impl,
    attrs = {
        "abi_flags": attr.string(default = ""),
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

        python_target_settings = [
            version_setting,
            freethreaded_setting,
        ]
        runtime_target_settings = (
            python_target_settings +
            [":" + name for name in platform_setting_names] +
            extra_config_settings
        )

        # target_settings are evaluated against the target configuration even
        # for a toolchain whose implementation runs on the execution platform:
        # https://bazel.build/reference/be/general#toolchain.target_settings
        # Select the requested Python version and mode, but do not require the
        # execution interpreter to match target-platform settings such as libc.
        exec_target_settings = python_target_settings + extra_config_settings

        runtime_target_compatible_with = info["compatible_with"] + extra_target_compatible
        exec_compatible_with = info["compatible_with"] + extra_exec_compatible

        # Root target constraints describe which targets may use the exec
        # toolchain. PBS OS/CPU constraints describe only its exec platform:
        # https://bazel.build/reference/be/general#toolchain.target_compatible_with
        exec_target_compatible_with = extra_target_compatible

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
    target_compatible_with = {runtime_target_compatible_with},
    target_settings = {runtime_target_settings},
    toolchain = "@{repo}//:runtime_pair",
    toolchain_type = "@bazel_tools//tools/python:toolchain_type",
)
""".format(
            name = info["name"],
            repo = info["repo"],
            runtime_target_settings = runtime_target_settings,
            runtime_target_compatible_with = runtime_target_compatible_with,
        ))

        if info["register_exec_tools"]:
            content.append("""# Exec tools run on the selected execution platform for this target's
# Python mode.
toolchain(
    name = "{name}_exec_tools",
    exec_compatible_with = {exec_compatible_with},
    target_compatible_with = {exec_target_compatible_with},
    target_settings = {exec_target_settings},
    toolchain = "@{repo}//:exec_tools_toolchain",
    toolchain_type = "@rules_python//python:exec_tools_toolchain_type",
)
""".format(
                name = info["name"],
                repo = info["repo"],
                exec_compatible_with = exec_compatible_with,
                exec_target_compatible_with = exec_target_compatible_with,
                exec_target_settings = exec_target_settings,
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
