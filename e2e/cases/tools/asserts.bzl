"""Test helper"""

load("@aspect_rules_py//py:defs.bzl", "py_test")
load("@bazel_lib//lib:write_source_files.bzl", "write_source_file")

# Path substrings that must never appear in any image layer. These ship via
# the venv/runfiles source layer only if something bypasses the pip-package
# layer's `_should_skip_pkg_path` filter — e.g. a reintroduced
# `_wheels/<key>` intermediate tree, which also re-duplicates wheel files.
# Asserted by a Docker-free py_test (see assert_tar_listing); intentionally an
# invariant, not exact bytes, so it survives snapshot regeneration. Keyed by
# the image's first-party bytecode mode: pip layers are always stripped of
# bytecode, but first-party bytecode is expected under `pyc`/`pyc_only`.
_FORBIDDEN_LAYER_PATHS = {
    "source": ["__pycache__", "[.]pyc", "/_wheels/"],
    "pyc": ["site-packages/.*[.]pyc", "/_wheels/"],
    "pyc_only": ["__pycache__", "site-packages/.*[.]pyc", "/_wheels/"],
}

# Paths whose byte size varies across Bazel releases or builds. We keep
# the rows in the listing (so a missing/renamed file would still be
# caught) but redact the size column so a single snapshot works across
# Bazel-version bumps.
_VOLATILE_SIZE_PATHS = [
    "/_repo_mapping",
]

# Paths to drop from the listing entirely. Bazel 8 ships runfiles.bash via
# @bazel_tools, Bazel 9 routes it through @rules_shell at a different
# runfiles path — neither this rule nor the user-facing image cares which,
# so filter the row out so one snapshot works on both.
#
# Callers pass `exclude` to drop more, for snapshots that only need to
# demonstrate one property of the rows they keep.
_FILTERED_PATHS = [
    "/bazel_tools/tools/bash/runfiles/runfiles.bash",
]

def assert_tar_listing(name, actual, expected, exclude = [], disjoint = True, pyc = "source", **kwargs):
    """Snapshot and invariant tests over the tar listings of image layers.

    Renders `bsdtar -tv` rows for every tar in `actual` into one multi-layer
    listing, then declares three targets:

      - `name`: a `write_source_file` snapshot of the listing at
        `snapshots/<expected>` (byte-exact; `bazel run` the target to update).
      - `name + "_layers_disjoint"`: asserts no file or symlink destination
        ships in more than one layer (directories are exempt). Guards the
        mtree-action skip set — a missed exclusion double-ships bytes without
        failing any build step.
      - `name + "_no_forbidden_paths"`: asserts stripped bytecode/metadata and
        `_wheels/` smuggling trees never reappear. Unlike the snapshot, this
        cannot be silenced by regeneration.

    Args:
        name: base name for the generated targets.
        actual: labels producing the layer tars, in layer order.
        expected: file name of the snapshot under `snapshots/`.
        exclude: extra path substrings whose rows are dropped from the
            snapshot listing only, for snapshots that only demonstrate the
            rows they keep. The disjointness test always sees every row.
        disjoint: set False to skip the disjointness test for layouts with
            intentional cross-layer overlap.
        pyc: the image's `pyc` mode; selects which bytecode paths are forbidden.
        **kwargs: forwarded to the `write_source_file` snapshot target.
    """
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
  # both the right-aligned padding spaces and the digits with a single
  # ` *` token. Digit-count-agnostic so a single snapshot survives
  # cross-platform size drift (e.g. `_repo_mapping` rendered as 4 vs 5
  # digits across builds). The size lives right before the `Jan 1 2023`
  # timestamp that mtree pins on every entry, so `<spaces><digits> Jan`
  # is unambiguous. Loses column alignment on the redacted row only —
  # snapshot diffs are byte-exact, not visual, so alignment doesn't
  # matter.
  TZ="UTC" LC_ALL="en_US.UTF-8" $(BSDTAR_BIN) -tvf $$f \\
    | awk -v volatile='{volatile}' -v filtered='{filtered}' '
        BEGIN {{
            n = split(volatile, paths, "|")
            nf = split(filtered, fpaths, "|")
        }}
        {{
            # Drop rows for Bazel-version-sensitive paths entirely.
            for (j = 1; j <= nf; j++) {{
                if (fpaths[j] != "" && index($$0, fpaths[j])) next
            }}
            for (i = 1; i <= n; i++) {{
                if (paths[i] != "" && index($$0, paths[i]) && match($$0, /[ ]+[0-9]+ Jan/)) {{
                    # RLENGTH spans leading spaces + digits + " Jan".
                    # Keep the " Jan" suffix (4 chars); replace the rest.
                    $$0 = substr($$0, 1, RSTART - 1) " *" substr($$0, RSTART + RLENGTH - 4)
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
            filtered = "|".join(_FILTERED_PATHS + exclude),
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

    # Invariant tests below share the snapshot target's test filtering.
    test_kwargs = {k: kwargs[k] for k in ("tags", "size", "timeout") if k in kwargs}

    # A missed `covered_files` contribution double-ships bytes without
    # failing any build step; this is the guard. It reads its own unfiltered
    # listing: `exclude`/_FILTERED_PATHS rows must stay visible here or a
    # double-shipped excluded path would pass unnoticed.
    if disjoint:
        disjoint_listing = "{}_disjoint_listing".format(name)
        native.genrule(
            name = disjoint_listing,
            srcs = actual,
            testonly = True,
            outs = ["_{}_disjoint.listing".format(name)],
            cmd = """\
iter=0
for f in $(SRCS); do
  echo "layer: $$iter"
  TZ="UTC" LC_ALL="en_US.UTF-8" $(BSDTAR_BIN) -tvf $$f | sed "s/^/  - /g"
  iter=$$(($$iter + 1))
done > $@
""",
            toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
        )
        py_test(
            name = "{}_layers_disjoint".format(name),
            srcs = ["//tools:assert_disjoint.py"],
            main = "//tools:assert_disjoint.py",
            args = ["$(rootpath :{})".format(disjoint_listing)],
            data = [":{}".format(disjoint_listing)],
            testonly = True,
            **test_kwargs
        )

    # Docker-free invariant guard over the same listing: assert the stripped
    # bytecode/metadata (and any `_wheels/<key>` smuggling tree) never reappear
    # in a layer. Complements the byte-exact snapshot above — regenerating the
    # snapshot can't make this pass.
    py_test(
        name = "{}_no_forbidden_paths".format(name),
        srcs = ["//tools:assert_absent.py"],
        main = "//tools:assert_absent.py",
        args = ["$(rootpath :{})".format(actual_listing)] + _FORBIDDEN_LAYER_PATHS[pyc],
        data = [":{}".format(actual_listing)],
        testonly = True,
        **test_kwargs
    )

# buildifier: disable=function-docstring
def assert_tar_ownership(name, actual, owner, group, **kwargs):
    actual_listing = "{}_listing".format(name)
    native.genrule(
        name = actual_listing,
        srcs = actual,
        testonly = True,
        outs = ["_{}.listing".format(name)],
        cmd = """\
for f in $(SRCS); do
  TZ="UTC" LC_ALL="en_US.UTF-8" $(BSDTAR_BIN) -tvf $$f | sed "s/^/  - /g"
done > $@
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    py_test(
        name = name,
        srcs = ["//tools:assert_ownership.py"],
        main = "//tools:assert_ownership.py",
        args = [
            "$(rootpath :{})".format(actual_listing),
            owner,
            group,
        ],
        data = [":{}".format(actual_listing)],
        testonly = True,
        **kwargs
    )
