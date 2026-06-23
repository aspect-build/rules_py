"""Repository rules for Python interpreter toolchains."""

load("@bazel_features//:features.bzl", features = "bazel_features")
load(":exclude_feature.bzl", "INTERPRETER_FEATURES")

_PYTHON_VERSION_FLAG = ":python_version"
_RPY_VERSION_MAJOR_MINOR_FLAG = "@rules_python//python/config_settings:python_version_major_minor"
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
    is_macos = "apple-darwin" in platform
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

    if is_macos and rctx.os.name.lower().startswith("mac os"):
        # Match rules_python's PBS repository setup so extensions link to the
        # relocatable dylib rather than its build-host install name:
        # https://github.com/bazel-contrib/rules_python/blob/1.9.1/python/private/python_repository.bzl#L111-L124
        suffix = "t" if rctx.attr.freethreaded else ""
        dylib = "libpython{}.{}{}.dylib".format(major, minor, suffix)
        install_name_tool = rctx.which("install_name_tool")
        if not install_name_tool:
            fail("install_name_tool is required to register the macOS Python C toolchain")
        result = rctx.execute([
            install_name_tool,
            "-id",
            "@rpath/{}".format(dylib),
            "lib/{}".format(dylib),
        ])
        if result.return_code:
            fail("install_name_tool failed: {}".format(result.stderr))

    # Delete terminfo symlink loops on newer PBS releases (linux only)
    if "linux" in platform:
        rctx.delete("share/terminfo")

    rctx.file("BUILD.bazel", content = _python_interpreter_build_file_content(
        freethreaded = rctx.attr.freethreaded,
        major = major,
        minor = minor,
        micro = micro,
        platform = platform,
        python_bin = python_bin,
        releaselevel = releaselevel,
        serial = serial,
    ))

    if not features.external_deps.extension_metadata_has_reproducible:
        return None

    # The macOS archive is rewritten on macOS hosts but not cross-build hosts,
    # so its repository output is not host-independent.
    return rctx.repo_metadata(reproducible = not is_macos)

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

def _python_interpreter_build_file_content(major, minor, micro, platform, python_bin, freethreaded, releaselevel, serial):
    """Generate the full BUILD.bazel content for an interpreter repo."""

    is_windows = "windows" in platform
    feature_targets, feature_excludes = _feature_filegroups(major, minor, is_windows)

    if is_windows:
        core_include = '["**/*.py", "**/*.pyd", "**/*.dll", "**/*.exe", "include/**", "Lib/**", "tcl/**"]'
        core_exclude = '["Lib/**/test/**", "Lib/**/tests/**", "**/__pycache__/*.pyc*"]'
        suffix = "t" if freethreaded else ""
        python_libs = [
            "python3{}.dll".format(suffix),
            "python{}{}{}.dll".format(major, minor, suffix),
            "libs/python3{}.lib".format(suffix),
            "libs/python{}{}{}.lib".format(major, minor, suffix),
        ]
        interface_targets = """
cc_import(
    name = "_python_interface",
    interface_library = "libs/python{major}{minor}{suffix}.lib",
    system_provided = True,
)

cc_import(
    name = "_python_abi3_interface",
    interface_library = "libs/python3{suffix}.lib",
    system_provided = True,
)
""".format(major = major, minor = minor, suffix = suffix)
        full_header_deps = '[":python_headers_abi3", ":_python_interface"]'
        abi3_header_deps = '[":_python_abi3_interface"]'
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
        suffix = "t" if freethreaded else ""
        if "apple-darwin" in platform:
            python_libs = ["lib/libpython{}.{}{}.dylib".format(major, minor, suffix)]
        else:
            python_libs = [
                "lib/libpython{}.{}{}.so".format(major, minor, suffix),
                "lib/libpython{}.{}{}.so.1.0".format(major, minor, suffix),
            ]
        interface_targets = ""
        full_header_deps = '[":python_headers_abi3"]'
        abi3_header_deps = "[]"

    python_includes = [
        "include",
        "include/python{}.{}{}".format(major, minor, suffix),
    ]
    if not freethreaded:
        python_includes.append("include/python{}.{}m".format(major, minor))
    abi_flags = "t" if freethreaded else ""

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
load("@rules_cc//cc:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_python//python:py_exec_tools_toolchain.bzl", "py_exec_tools_toolchain")
load("@rules_python//python:py_runtime.bzl", "py_runtime")
load("@rules_python//python:py_runtime_pair.bzl", "py_runtime_pair")
load("@rules_python//python/cc:py_cc_toolchain.bzl", "py_cc_toolchain")

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
        "releaselevel": "{releaselevel}",
        "serial": "{serial}",
    }},
    abi_flags = "{abi_flags}",
    implementation_name = "cpython",
    # Free-threaded CPython keeps the same cache tag without a `t` ABI flag:
    # https://github.com/python/cpython/blob/v3.15.0a5/Python/sysmodule.c#L3570-L3576
    pyc_tag = "cpython-{major}{minor}",
    python_version = "PY3",
)

py_runtime_pair(
    name = "runtime_pair",
    py2_runtime = None,
    py3_runtime = ":py3_runtime",
)

interpreter_executable(
    name = "exec_interpreter",
    runtime_pair = ":runtime_pair",
)

{interface_targets}

filegroup(
    name = "_python_headers",
    srcs = glob(["include/**/*.h"]),
)

cc_library(
    name = "python_headers_abi3",
    hdrs = [":_python_headers"],
    includes = {python_includes},
    deps = {abi3_header_deps},
)

cc_library(
    name = "python_headers",
    deps = {full_header_deps},
)

cc_library(
    name = "libpython",
    hdrs = [":_python_headers"],
    srcs = {python_libs},
)

py_cc_toolchain(
    name = "py_cc_toolchain",
    headers = ":python_headers",
    headers_abi3 = ":python_headers_abi3",
    libs = ":libpython",
    python_version = "{major}.{minor}",
)

py_exec_tools_toolchain(
    name = "exec_tools_toolchain",
    exec_interpreter = ":exec_interpreter",
    precompiler = "@rules_python//tools/precompiler:precompiler",
)
""".format(
        abi_flags = abi_flags,
        python_bin = python_bin,
        major = major,
        minor = minor,
        micro = micro,
        releaselevel = releaselevel,
        serial = serial,
        feature_targets = feature_targets,
        feature_selects = feature_selects,
        interface_targets = interface_targets,
        full_header_deps = full_header_deps,
        abi3_header_deps = abi3_header_deps,
        python_libs = repr(python_libs),
        python_includes = repr(python_includes),
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

def _sanitize(value):
    return value.replace(".", "_").replace("-", "_").replace("+", "_")

def _target_platform_setting_name(platform):
    return "target_platform_is_" + _sanitize(platform)

def _version_setting_name(major_minor):
    """Generate config_setting name for a Python version."""
    return "python_version_is_" + major_minor.replace(".", "_")

def _freethreaded_setting_name(value):
    """Generate config_setting name for the freethreaded flag."""
    return "freethreaded_is_" + ("true" if value else "false")

def _python_toolchains_impl(rctx):
    """Creates toolchain() registrations pointing to interpreter repos."""
    content = [
        'load("@bazel_skylib//rules:common_settings.bzl", "string_flag")',
        'load("@bazel_skylib//lib:selects.bzl", "selects")',
        'load("@aspect_rules_py//py/private/interpreter:current_py_toolchain.bzl", "current_py_toolchain")',
        'package(default_visibility = ["//visibility:public"])',
        """string_flag(
    name = "python_version",
    build_setting_default = {default_python_version},
)""".format(default_python_version = repr(rctx.attr.default_python_version)),
    ]

    # Collect each target platform and version/config combination once.
    target_platforms = {}
    seen_versions = {}  # major_minor -> True
    seen_freethreaded = {}  # bool -> True
    target_toolchain_infos = []
    exec_toolchain_infos = [json.decode(entry) for entry in rctx.attr.exec_toolchains]

    for entry in rctx.attr.target_toolchains:
        info = json.decode(entry)
        platform = info["platform"]
        platform_info = {
            "compatible_with": info["compatible_with"],
            "target_settings": info.get("platform_target_settings", {}),
        }
        if platform in target_platforms and target_platforms[platform] != platform_info:
            fail("Conflicting target platform settings for {}".format(platform))
        target_platforms[platform] = platform_info
        python_version = info["python_version"]
        seen_versions[python_version] = True
        seen_freethreaded[info.get("freethreaded", False)] = True
        target_toolchain_infos.append(info)

    for info in exec_toolchain_infos:
        seen_versions[info["python_version"]] = True
        seen_freethreaded[info.get("freethreaded", False)] = True

    # Emit hub-local version config_settings so toolchain resolution doesn't
    # need to fetch individual interpreter repos.
    for major_minor in seen_versions.keys():
        group_name = _version_setting_name(major_minor)
        content.append("""
# rules_python target transitions set only their own flag. Prefer a nonempty
# rules_python value; use the generated root default only while it is empty.
config_setting(
    name = "_{group}_rpy",
    flag_values = {{"{rpy_major_minor_flag}": "{major_minor}"}},
)

config_setting(
    name = "_{group}_our_fallback",
    flag_values = {{
        "{our_flag}": "{major_minor}",
        "{rpy_major_minor_flag}": "",
    }},
)

selects.config_setting_group(
    name = "{group}",
    match_any = [
        ":_{group}_rpy",
        ":_{group}_our_fallback",
    ],
)
""".format(
            group = group_name,
            major_minor = major_minor,
            our_flag = _PYTHON_VERSION_FLAG,
            rpy_major_minor_flag = _RPY_VERSION_MAJOR_MINOR_FLAG,
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

    # A cohort is a set of disjoint target platforms. Combining constraints and
    # target flags in one setting keeps libc target-side while still separating
    # GNU and musl Linux targets.
    for platform, platform_info in target_platforms.items():
        content.append("""
config_setting(
    name = "{name}",
    constraint_values = {constraint_values},
    flag_values = {flag_values},
)
""".format(
            name = _target_platform_setting_name(platform),
            constraint_values = platform_info["compatible_with"],
            flag_values = platform_info["target_settings"],
        ))

    seen_cohorts = {}
    for info in exec_toolchain_infos:
        cohort = info["cohort"]
        target_platform_names = [
            _target_platform_setting_name(platform)
            for platform in info["target_platforms"]
        ]
        if cohort in seen_cohorts:
            if seen_cohorts[cohort] != target_platform_names:
                fail("Conflicting target platforms for cohort {}".format(cohort))
            continue
        seen_cohorts[cohort] = target_platform_names
        content.append("""
selects.config_setting_group(
    name = "{name}",
    match_any = {target_platforms},
)
""".format(
            name = cohort,
            target_platforms = [":" + name for name in target_platform_names],
        ))

    # Target runtime and C registrations retain their stable names and exact
    # target-platform compatibility.
    for info in target_toolchain_infos:
        extra_config_settings = info.get("config_settings", [])
        extra_target_compatible = info.get("target_compatible_with", [])

        version_setting = ":" + _version_setting_name(info["python_version"])
        freethreaded_setting = ":" + _freethreaded_setting_name(info.get("freethreaded", False))
        target_settings = [
            version_setting,
            freethreaded_setting,
            ":" + _target_platform_setting_name(info["platform"]),
        ] + extra_config_settings

        target_compatible_with = info["compatible_with"] + extra_target_compatible
        py_cc_name = "py_cc_" + info["name"]

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

toolchain(
    name = "{py_cc_name}",
    target_compatible_with = {target_compatible_with},
    target_settings = {target_settings},
    toolchain = "{py_cc_toolchain}",
    toolchain_type = "@rules_python//python/cc:toolchain_type",
)
""".format(
            name = info["name"],
            repo = info["repo"],
            target_compatible_with = target_compatible_with,
            target_settings = target_settings,
            py_cc_name = py_cc_name,
            py_cc_toolchain = info["py_cc_toolchain"],
        ))

    # Each exact target cohort gets at most one registration per supported
    # executor platform. The cohort group selects all target platforms sharing
    # the release, full version, and logical build configuration.
    for info in exec_toolchain_infos:
        exec_target_settings = [
            ":" + _version_setting_name(info["python_version"]),
            ":" + _freethreaded_setting_name(info.get("freethreaded", False)),
            ":" + info["cohort"],
        ] + info.get("config_settings", [])
        exec_compatible_with = info["compatible_with"] + info.get("exec_compatible_with", [])
        target_compatible_with = info.get("target_compatible_with", [])
        content.append("""
toolchain(
    name = "{name}_exec_tools",
    exec_compatible_with = {exec_compatible_with},
    target_compatible_with = {target_compatible_with},
    target_settings = {exec_target_settings},
    toolchain = "@{repo}//:exec_tools_toolchain",
    toolchain_type = "@rules_python//python:exec_tools_toolchain_type",
)
""".format(
            name = info["name"],
            repo = info["repo"],
            exec_compatible_with = exec_compatible_with,
            target_compatible_with = target_compatible_with,
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
        "default_python_version": attr.string(),
        "exec_toolchains": attr.string_list(),
        "target_toolchains": attr.string_list(),
    },
)
