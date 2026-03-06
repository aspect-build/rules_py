"""Repository rules for downloading Python interpreters from python-build-standalone."""

load(":versions.bzl", "DEFAULT_RELEASE_BASE_URL")

def _python_interpreter_impl(rctx):
    """Downloads and extracts a Python interpreter from PBS."""
    python_version = rctx.attr.python_version
    platform = rctx.attr.platform
    url = rctx.attr.url
    sha256 = rctx.attr.sha256
    strip_prefix = rctx.attr.strip_prefix

    if not url:
        fail("url must be provided")

    rctx.download_and_extract(
        url = [url],
        sha256 = sha256,
        stripPrefix = strip_prefix,
    )

    python_bin = "python.exe" if "windows" in platform else "bin/python3"
    version_parts = python_version.split(".")
    major = version_parts[0]
    minor = version_parts[1]
    micro = version_parts[2] if len(version_parts) > 2 else "0"

    # Delete __pycache__ pyc files to prevent cache invalidation
    # Also delete terminfo symlink loops on newer PBS releases (linux only)
    if "linux" in platform:
        rctx.delete("share/terminfo")

    rctx.file("BUILD.bazel", content = """\
load("@rules_python//python:py_runtime.bzl", "py_runtime")
load("@rules_python//python:py_runtime_pair.bzl", "py_runtime_pair")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(
        include = [
            "bin/**",
            "include/**",
            "lib/**",
            "share/**",
        ],
        exclude = [
            "lib/**/*.a",
            "lib/python{major}.{minor}/**/test/**",
            "lib/python{major}.{minor}/**/tests/**",
            "**/__pycache__/*.pyc*",
        ],
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
        python_bin = python_bin,
        major = major,
        minor = minor,
        micro = micro,
    ))

python_interpreter = repository_rule(
    implementation = _python_interpreter_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
        "python_version": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = "python"),
        "url": attr.string(mandatory = True),
    },
)

def _python_toolchains_impl(rctx):
    """Creates toolchain() registrations pointing to interpreter repos."""
    content = ['package(default_visibility = ["//visibility:public"])']

    for entry in rctx.attr.toolchains:
        # entry is a JSON string: {"name": ..., "repo": ..., "compatible_with": [...], "python_version": ...}
        info = json.decode(entry)
        content.append("""
toolchain(
    name = "{name}",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {compatible_with},
    toolchain = "@{repo}//:runtime_pair",
    toolchain_type = "@bazel_tools//tools/python:toolchain_type",
)
""".format(
            name = info["name"],
            repo = info["repo"],
            compatible_with = info["compatible_with"],
        ))

    rctx.file("BUILD.bazel", content = "\n".join(content))

python_toolchains = repository_rule(
    implementation = _python_toolchains_impl,
    attrs = {
        "toolchains": attr.string_list(),
    },
)
