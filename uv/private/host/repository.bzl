"""Host config for constraints.

Inspect the build host and decide default values for the various build
constraints such as the libc version or the darwin version as needed. This
allows for compatible prebuilds to be selected by default.

"""

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

def _platform(rctx):
    os = _translate_os(rctx.os.name)

    if os == "osx":
        res = rctx.execute(["sw_vers", "-productVersion"])
        ver = res.stdout.split(".")
        return "libsystem", "{}.{}".format(ver[0], ver[1])

    elif os == "linux":
        res = rctx.execute(["ldd", "--version"])

        libc = "musllinux" if "musl" in res.stdout else "manylinux"
        if libc == "musllinux":
            ver = res.stdout.split("\n")[1].split(" ")[-1].split(".")
            return libc, "{}.{}".format(ver[0], ver[1])

        elif libc == "manylinux":
            ver = res.stdout.split("\n")[0].split(" ")[-1].split(".")
            return libc, "{}.{}".format(ver[0], ver[1])

    # TODO: Windows
    # TODO: Other

    fail("Unsupported platform {}".format(os))

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
