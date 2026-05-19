"""Test helper"""

load("@bazel_lib//lib:write_source_files.bzl", "write_source_file")

# Paths whose byte size varies across Bazel releases or builds. We keep
# the rows in the listing (so a missing/renamed file would still be
# caught) but redact the size column so a single snapshot works across
# Bazel-version bumps.
_VOLATILE_SIZE_PATHS = [
    "/bazel_tools/tools/bash/runfiles/runfiles.bash",
    "/_repo_mapping",
]

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
  # Redact the size column for known-volatile rows in place, replacing
  # each digit with `*`. Preserves byte length and column alignment so
  # the rest of the listing stays comparable across Bazel versions. The
  # size lives right before the `Jan 1 2023` timestamp that mtree pins
  # on every entry, so a `<digits> Jan` anchor is unambiguous.
  TZ="UTC" LC_ALL="en_US.UTF-8" $(BSDTAR_BIN) -tvf $$f \\
    | awk -v volatile='{volatile}' '
        BEGIN {{ n = split(volatile, paths, "|") }}
        {{
            for (i = 1; i <= n; i++) {{
                if (paths[i] != "" && index($$0, paths[i]) && match($$0, /[0-9]+ Jan/)) {{
                    digits = RLENGTH - 4
                    repl = ""
                    for (j = 1; j <= digits; j++) repl = repl "*"
                    $$0 = substr($$0, 1, RSTART - 1) repl substr($$0, RSTART + digits)
                    break
                }}
            }}
            print
        }}' \\
    | sort -k9 | sed "s/^/  - /g"
  iter=$$(($$iter + 1))
done > $@
""".format(
            volatile = "|".join(_VOLATILE_SIZE_PATHS),
        ),
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    write_source_file(
        name = name,
        in_file = actual_listing,
        out_file = "snapshots/{}".format(expected),
        testonly = True,
        **kwargs
    )
