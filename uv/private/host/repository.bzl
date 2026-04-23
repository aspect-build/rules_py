"""Host platform detection repository rule.

Inspects the build host and emits default values for platform constraints
such as the libc family and version. This allows compatible prebuilt
artifacts to be selected by default.
"""

def _translate_os(os):
    """Normalize the OS name returned by Bazel to an internal identifier.

    Args:
      os: the string returned by `rctx.os.name`.

    Returns:
      One of "osx", "freebsd", "openbsd", "linux", "windows", or None.
    """
    if os.startswith("mac os"):
        return "osx"
    if os.startswith("freebsd"):
        return "freebsd"
    if os.startswith("openbsd"):
        return "openbsd"
    if os.startswith("linux"):
        return "linux"
    if os.startswith("windows"):
        return "windows"
    return None

def _platform(rctx):
    """Detect the host platform libc and version.

    On macOS this uses `sw_vers` to obtain the libsystem version.
    On Linux this uses `ldd --version` to distinguish between musl and glibc.

    Args:
      rctx: the repository context.

    Returns:
      A tuple `(libc, version)` where `libc` is a string such as
      "libsystem", "musl", or "glibc", and `version` is a "major.minor"
      string.
    """
    os = _translate_os(rctx.os.name)

    if os == "osx":
        res = rctx.execute(["sw_vers", "-productVersion"])
        ver = res.stdout.strip().split(".")
        return "libsystem", "{}.{}".format(ver[0], ver[1])

    elif os == "linux":
        res = rctx.execute(["ldd", "--version"])
        if res.return_code != 0:
            fail("Unable to determine host libc!")

        out = res.stdout.lower()

        if "musl" in out:
            ver = res.stdout.split("\n")[1].split(" ")[-1].split(".")
            return "musl", "{}.{}".format(ver[0], ver[1])

        elif "glibc" in out or "gnu libc" in out:
            ver = res.stdout.split("\n")[0].split(")")[1].strip().split(".")
            return "glibc", "{}.{}".format(ver[0], ver[1])

        else:
            fail("Unknown libc from ldd --version %r" % res.stdout)

    fail("Unsupported platform {}".format(os))

def _host_platform_repo_impl(rctx):
    """Generate a repository exposing host platform constraints."""
    rctx.file("BUILD.bazel", """
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "defs",
    srcs = ["defs.bzl"],
    visibility = ["//visibility:public"],
)
""")

    libc, version = _platform(rctx)

    rctx.file("defs.bzl", """
CURRENT_PLATFORM_LIBC = {}
CURRENT_PLATFORM_VERSION = {}
""".format(repr(libc), repr(version)))

host_platform_repo = repository_rule(
    implementation = _host_platform_repo_impl,
    doc = """Generates constraints for the host platform.

The generated `defs.bzl` file contains `CURRENT_PLATFORM_LIBC` and
`CURRENT_PLATFORM_VERSION`, which can be consumed by other build logic
to select compatible prebuilt artifacts.
""",
    local = True,
)
