"""Host config for constraints.

Inspect the build host and decide default values for the various build
constraints such as the libc version or the darwin version as needed. This
allows for compatible prebuilds to be selected by default.

"""

# Reported when the host's libc cannot be probed, for example because `ldd` or
# `sw_vers` is not on PATH in a hermetic or sandboxed fetch. Prebuilt wheels
# that need a newer libc than this are skipped in favour of an older wheel or
# the sdist; set `platform_version` to pick a different floor.
FALLBACK_GLIBC_VERSION = "2.28"
FALLBACK_MUSL_VERSION = "1.2"
FALLBACK_MACOS_VERSION = "11.0"

def _translate_os(os):
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

def parse_sw_vers(stdout):
    """Parse `sw_vers -productVersion` output.

    Args:
        stdout: The command's stdout, or None if it could not be run.

    Returns:
        The ("libsystem", "<major>.<minor>") tuple, or None if `stdout` holds no version.
    """
    ver = (stdout or "").strip().split(".")
    if not ver[0].isdigit():
        return None
    return "libsystem", "{}.{}".format(ver[0], ver[1] if len(ver) > 1 and ver[1].isdigit() else "0")

def parse_ldd_version(stdout):
    """Parse `ldd --version` output.

    Args:
        stdout: The command's stdout, or None if it could not be run.

    Returns:
        A (libc, "<major>.<minor>") tuple, or None if `stdout` names no known libc.
    """
    if not stdout:
        return None
    out = stdout.lower()

    # - Alpine: "musl libc ...\nversion <ver>\n ..."
    if "musl" in out:
        lines = stdout.split("\n")
        if len(lines) < 2:
            return None
        ver = lines[1].split(" ")[-1].split(".")
        if len(ver) < 2:
            return None
        return "musl", "{}.{}".format(ver[0], ver[1])

    # - Amazon Linux: "ldd (gnu libc ...) <ver>\n..."
    # - Arch Linux: "ldd (gnu libc ...) <ver>\n..."
    # - Debian: "ldd (debian glibc <ver><platformver>) <ver>\n..."
    # - Fedora: "ldd (gnu libc ...) <ver>\n..."
    # - Gentoo: "ldd (gentoo <ver><platformver>) <ver>\n..."
    # - Oracle Linux: "ldd (gnu libc ...) <ver>\n..."
    # - Ubuntu: "ldd (ubuntu glibc <ver><platformver>) <ver>\n..."
    if "glibc" in out or "gnu libc" in out or "gentoo" in out:
        ver = stdout.split("\n")[0].split(")")[-1].strip().split(".")
        if len(ver) < 2:
            return None
        return "glibc", "{}.{}".format(ver[0], ver[1])

    return None

def host_libc(os, probe_stdout, has_musl_loader = False):
    """Decide the host libc and its version.

    Args:
        os: The host OS as returned by `_translate_os`.
        probe_stdout: Output of `sw_vers -productVersion` on macOS or
            `ldd --version` on Linux; None if the tool could not be run.
        has_musl_loader: Whether the host has a musl dynamic loader, used to
            pick the fallback libc when `ldd` could not be run.

    Returns:
        A (libc, version) tuple.
    """
    if os == "osx":
        return parse_sw_vers(probe_stdout) or ("libsystem", FALLBACK_MACOS_VERSION)

    elif os == "linux":
        if probe_stdout == None:
            if has_musl_loader:
                return "musl", FALLBACK_MUSL_VERSION
            return "glibc", FALLBACK_GLIBC_VERSION
        parsed = parse_ldd_version(probe_stdout)
        if parsed == None:
            fail("Unknown libc from ldd --version %r" % probe_stdout)
        return parsed

    elif os == "windows":
        # Windows wheel tags encode no runtime version, so only the libc slot is meaningful.
        return "msvc", "0.0"

    # TODO: Other

    fail("Unsupported platform {}".format(os))

def _probe(rctx, tool, args, fallback_paths = []):
    """Run `tool args`, returning stdout or None if the tool is missing or fails."""
    path = rctx.which(tool)
    if path == None:
        for candidate in fallback_paths:
            if rctx.path(candidate).exists:
                path = candidate
                break
    if path == None:
        return None
    res = rctx.execute([path] + args)
    if res.return_code != 0:
        return None
    return res.stdout

def _has_musl_loader(rctx):
    lib = rctx.path("/lib")
    if not lib.exists:
        return False
    for entry in lib.readdir():
        if entry.basename.startswith("ld-musl-"):
            return True
    return False

def _platform(rctx):
    os = _translate_os(rctx.os.name)
    if os == "osx":
        return host_libc(os, _probe(rctx, "sw_vers", ["-productVersion"], ["/usr/bin/sw_vers"]))
    elif os == "linux":
        stdout = _probe(rctx, "ldd", ["--version"])
        return host_libc(os, stdout, has_musl_loader = stdout == None and _has_musl_loader(rctx))
    return host_libc(os, None)

def _host_platform_repo_impl(rctx):
    rctx.file("BUILD.bazel", """
# DO NOT EDIT: automatically generated BUILD file
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "defs",
    srcs = ["defs.bzl"],
    visibility = ["//visibility:public"],
)
""")

    libc, version = _platform(rctx)

    rctx.file("defs.bzl", """
# DO NOT EDIT: automatically generated constraints list
CURRENT_PLATFORM_LIBC = {}
CURRENT_PLATFORM_VERSION = {}
""".format(repr(libc), repr(version)))

host_platform_repo = repository_rule(
    implementation = _host_platform_repo_impl,
    doc = """Generates constraints for the host platform. The constraints.bzl
file contains a single <code>HOST_CONSTRAINTS</code> variable, which is a
list of strings, each of which is a label to a <code>constraint_value</code>
for the host platform.""",
    local = True,
)
