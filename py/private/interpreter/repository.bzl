"""Repository rules for downloading Python interpreters from python-build-standalone."""

load(":versions.bzl", "BUILD_CONFIGS", "DEFAULT_RELEASE_BASE_URL")
_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_FREETHREADING_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"

# BUILD file for version/platform combinations that don't exist in a release.
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

# Freethreaded matching: use "true" so it only matches when the freethreaded
# flag is explicitly set, which combined with the version sentinel means this
# toolchain is never selected.
config_setting(
    name = "is_matching_freethreaded",
    flag_values = {{"{freethreading_flag}": "true"}},
)
"""

def _parse_sha256sums(content, release_date, major_minor, platform, build_config):
    """Parse SHA256SUMS to find the matching asset.

    Returns a struct with url_suffix, sha256, and full_version, or None if not found.
    """
    config_info = BUILD_CONFIGS[build_config]
    suffix = config_info["suffix"]
    ext = config_info["extension"]

    # We're looking for a line like:
    #   abc123  cpython-3.11.14+20251209-x86_64-unknown-linux-gnu-install_only.tar.gz
    # where the version starts with our major_minor prefix.
    expected_middle = "+{}-{}-{}.{}".format(release_date, platform, suffix, ext)

    best_version = None
    best_sha256 = None
    best_filename = None

    for line in content.split("\n"):
        line = line.strip()
        if not line:
            continue

        parts = line.split("  ", 1)
        if len(parts) != 2:
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue

        sha256 = parts[0].strip()
        filename = parts[1].strip()

        if not filename.startswith("cpython-"):
            continue

        # Check if this file matches our platform and build config
        # The filename format is: cpython-{version}+{date}-{platform}-{suffix}.{ext}
        if expected_middle not in filename:
            continue

        # Extract version from filename
        version_part = filename[len("cpython-"):filename.index("+")]

        # Check if version matches our major.minor
        version_parts = version_part.split(".")
        if len(version_parts) < 2:
            continue
        file_major_minor = "{}.{}".format(version_parts[0], version_parts[1])
        if file_major_minor != major_minor:
            continue

        # Prefer the newest patch version
        if best_version == None or _version_gt(version_part, best_version):
            best_version = version_part
            best_sha256 = sha256
            best_filename = filename

    if best_version == None:
        return None

    return struct(
        filename = best_filename,
        sha256 = best_sha256,
        full_version = best_version,
    )

def _version_gt(a, b):
    """Returns True if version string a > b."""
    a_parts = [int(x) for x in a.split(".")]
    b_parts = [int(x) for x in b.split(".")]
    for i in range(max(len(a_parts), len(b_parts))):
        a_val = a_parts[i] if i < len(a_parts) else 0
        b_val = b_parts[i] if i < len(b_parts) else 0
        if a_val > b_val:
            return True
        if a_val < b_val:
            return False
    return False

def _python_interpreter_impl(rctx):
    """Downloads and extracts a Python interpreter from PBS.

    This rule discovers the exact patch version and SHA256 checksum by
    downloading the SHA256SUMS file from the PBS release, then downloads
    the matching interpreter archive.
    """
    release_date = rctx.attr.release_date
    major_minor = rctx.attr.major_minor
    platform = rctx.attr.platform
    build_config = rctx.attr.build_config
    release_base_url = rctx.attr.release_base_url

    config_info = BUILD_CONFIGS[build_config]

    # Download SHA256SUMS for this release
    sha256sums_url = "{}/{}/SHA256SUMS".format(release_base_url, release_date)
    rctx.download(
        url = [sha256sums_url],
        output = "SHA256SUMS",
    )
    sha256sums_content = rctx.read("SHA256SUMS")
    rctx.delete("SHA256SUMS")

    # Find our asset in the SHA256SUMS
    match = _parse_sha256sums(sha256sums_content, release_date, major_minor, platform, build_config)
    if match == None:
        # This version/platform/config combination doesn't exist in this release.
        # Generate a stub BUILD file so the toolchain hub can still reference our
        # targets, but the toolchain will never be selected (the config_settings
        # use a sentinel version that never matches).
        rctx.file("BUILD.bazel", content = _UNAVAILABLE_BUILD.format(
            our_flag = _PYTHON_VERSION_FLAG,
            rpy_flag = _RPY_VERSION_FLAG,
            freethreading_flag = _FREETHREADING_FLAG,
        ))
        return

    python_version = match.full_version
    sha256 = match.sha256
    url = "{}/{}/{}".format(release_base_url, release_date, match.filename)

    # Download and extract the interpreter
    rctx.download_and_extract(
        url = [url],
        sha256 = sha256,
        stripPrefix = config_info["strip_prefix"],
    )

    # Determine the Python binary path
    python_bin = "python.exe" if "windows" in platform else "bin/python3"
    version_parts = python_version.split(".")
    major = version_parts[0]
    minor = version_parts[1]
    micro = version_parts[2] if len(version_parts) > 2 else "0"
    major_minor_str = "{}.{}".format(major, minor)
    is_freethreaded = config_info["freethreaded"]

    is_windows = "windows" in platform

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

# Config settings that match when python_version is set to this interpreter's
# version (either "X.Y" or "X.Y.Z"). Both our own flag and the rules_python
# flag are checked so that toolchain resolution works regardless of which flag
# is being set.
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
        major_minor = major_minor_str,
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
        "build_config": attr.string(default = "install_only"),
        "major_minor": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        "release_base_url": attr.string(default = DEFAULT_RELEASE_BASE_URL),
        "release_date": attr.string(mandatory = True),
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
