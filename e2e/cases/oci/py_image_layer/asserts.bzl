"""Test helper"""

load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_lib//lib:write_source_files.bzl", "write_source_file")

# buildifier: disable=function-docstring
def assert_tar_listing(name, actual, expected, **kwargs):
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
        -tvf $$f | sort -k9 | sed "s/^/  - /g"
  iter=$$(($$iter + 1))
done > $@
""".format(actual),
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
        # HACK: avoid running tests that depend on this output on Bazel 9.
        # For some reason, the listing is different than on Bazel 8, in a way that's hard to scrub.
        target_compatible_with = ["@platforms//:incompatible"] if bazel_features.rules.merkle_cache_v2 else [],
    )

    write_source_file(
        name = name,
        in_file = actual_listing,
        out_file = expected,
        testonly = True,
        **kwargs
    )
