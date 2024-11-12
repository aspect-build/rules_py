load("@aspect_bazel_lib//lib:write_source_files.bzl", "write_source_file")

# buildifier: disable=function-docstring
def assert_tar_listing(name, actual, expected):
    actual_listing = "_{}_listing".format(name)
    native.genrule(
        name = actual_listing,
        srcs = actual,
        testonly = True,
        outs = ["_{}.listing".format(name)],
        cmd = 'echo $(SRCS) | TZ="UTC" LC_ALL="en_US.UTF-8" xargs -n 1 $(BSDTAR_BIN) -tvf > $@'.format(actual),
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    write_source_file(
        name = name,
        in_file = actual_listing,
        out_file = expected,
        testonly = True,
        tags = ["skip-on-bazel6"],
    )