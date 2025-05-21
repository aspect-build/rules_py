"""Test helper"""

load("@aspect_bazel_lib//lib:write_source_files.bzl", "write_source_file")

# buildifier: disable=function-docstring
def assert_tar_listing(name, actual, expected):
    actual_listing = "{}_listing".format(name)
    native.genrule(
        name = actual_listing,
        srcs = actual,
        testonly = True,
        outs = ["_{}.listing".format(name)],
        cmd = """\
iter=0
for f in $(SRCS); do
  echo "---"
  echo "layer: $$iter"
  echo "files:"
  TZ="UTC" LC_ALL="en_US.UTF-8" $(BSDTAR_BIN) \\
        --exclude "*/_repo_mapping" \\
        --exclude "**/tools/venv_bin/**" \\
        -tvf $$f | sort -k9 | sed "s/^/- /g"
  iter=$$(($$iter + 1))
done > $@
""".format(actual),
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    write_source_file(
        name = name,
        in_file = actual_listing,
        out_file = expected,
        testonly = True,
    )
