"""Compression coverage for `py_image_layer` layer tars.

The codec table, the bsdtar command lines the rule emits, and every
misconfiguration rejected at analysis time. That the bytes come out readable is
covered separately by `assert_compression.py`, which runs over the built tars.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//py/private:compression.bzl",
    "ALGORITHMS",
    "OCI_ALGORITHMS",
    "SUPPORTED_ALGORITHMS",
    "make_codec",
    "parse_compression",
)

_TAR_MNEMONICS = ["PyImageLayer", "PyImagePkgLayer", "PyImageMergedLayer"]

def _codec_table_test_impl(ctx):
    env = unittest.begin(ctx)

    gzip = make_codec("gzip", "6")
    asserts.equals(env, "--gzip", gzip.flag)
    asserts.equals(env, ".tar.gz", gzip.ext)

    # MTIME zeroed, so identical inputs keep producing identical layer digests.
    asserts.equals(env, "gzip:!timestamp,gzip:compression-level=6", gzip.options)

    zstd = make_codec("zstd", "19")
    asserts.equals(env, "--zstd", zstd.flag)
    asserts.equals(env, ".tar.zst", zstd.ext)
    asserts.equals(env, "zstd:compression-level=19", zstd.options)

    # No level: libarchive's own default, so no --options at all.
    xz = make_codec("xz", "")
    asserts.equals(env, "--xz", xz.flag)
    asserts.equals(env, ".tar.xz", xz.ext)
    asserts.equals(env, None, xz.options)

    # "none" is a plain uncompressed tar.
    none = make_codec("none", "")
    asserts.equals(env, None, none.flag)
    asserts.equals(env, ".tar", none.ext)
    asserts.equals(env, None, none.options)

    # libarchive rejects lz4 level 0 outright, unlike gzip/xz/lzma.
    asserts.equals(env, 1, ALGORITHMS["lz4"].min_level)
    asserts.equals(env, 0, ALGORITHMS["gzip"].min_level)

    # `compress` has no compression-level option module.
    asserts.equals(env, None, ALGORITHMS["compress"].filter)
    asserts.equals(env, ".tar.Z", make_codec("compress", "").ext)

    asserts.equals(env, make_codec("bzip2", ""), parse_compression(["bzip2"], "test"))
    asserts.equals(env, make_codec("bzip2", "9"), parse_compression(["bzip2", "9"], "test"))

    # The OCI image spec defines layer formats for exactly these three. Anything
    # else needs allow_non_oci_layers, because rules_oci would label it an
    # uncompressed tar and record the compressed digest as its diffid.
    asserts.equals(env, ["gzip", "none", "zstd"], OCI_ALGORITHMS)
    asserts.true(env, make_codec("zstd", "3").oci_compatible)
    asserts.false(env, make_codec("bzip2", "9").oci_compatible)
    asserts.false(env, make_codec("xz", "").oci_compatible)

    # Layer files are keyed by name in one directory, so extensions must differ.
    extensions = {}
    for name in SUPPORTED_ALGORITHMS:
        ext = ALGORITHMS[name].ext
        asserts.false(env, ext in extensions, "%s and %s share the extension %s" % (name, extensions.get(ext), ext))
        extensions[ext] = name

    return unittest.end(env)

codec_table_test = unittest.make(_codec_table_test_impl)

def _tar_action(env, suffix):
    """The tar action whose output ends with `suffix`, or None."""
    for action in analysistest.target_actions(env):
        if action.mnemonic not in _TAR_MNEMONICS:
            continue
        if action.outputs.to_list()[0].basename.endswith(suffix):
            return action
    return None

def _assert_tar_flags(env, suffix, expected):
    action = _tar_action(env, suffix)
    if action == None:
        names = [
            a.outputs.to_list()[0].basename
            for a in analysistest.target_actions(env)
            if a.mnemonic in _TAR_MNEMONICS
        ]
        unittest.fail(env, "no tar action produced *%s; saw %s" % (suffix, names))
        return
    for flag in expected:
        asserts.true(
            env,
            flag in action.argv,
            "expected %r in the bsdtar command line for *%s, got %s" % (flag, suffix, action.argv),
        )

def _rule_attrs_impl(ctx):
    env = analysistest.begin(ctx)

    _assert_tar_flags(env, "_default.tar.zst", ["--zstd", "--options", "zstd:compression-level=19"])
    _assert_tar_flags(env, "_assets.tar.xz", ["--xz"])

    # group_compress_levels stays the gzip shorthand for groups nothing else names.
    _assert_tar_flags(env, "_extras.tar.gz", ["--gzip", "--options", "gzip:!timestamp,gzip:compression-level=1"])

    return analysistest.end(env)

rule_attrs_test = analysistest.make(_rule_attrs_impl)

def _tier_compression_impl(ctx):
    env = analysistest.begin(ctx)

    # A first-party group named only by the tier picks up the tier's codec...
    _assert_tar_flags(env, "_branding.tar.bz2", ["--bzip2", "--options", "bzip2:compression-level=9"])

    # ...and the rule's own attr overrides the tier for the group it names.
    _assert_tar_flags(env, "_default.tar", [])
    asserts.true(
        env,
        "--gzip" not in _tar_action(env, "_default.tar").argv,
        "compression = none must not pass a filter flag",
    )

    return analysistest.end(env)

tier_compression_test = analysistest.make(_tier_compression_impl)

def _custom_compressor_impl(ctx):
    env = analysistest.begin(ctx)

    action = _tar_action(env, "_default.tar.lolz")
    if action == None:
        unittest.fail(env, "no tar action produced the custom-compressed source layer")
        return analysistest.end(env)

    asserts.true(env, "--use-compress-program" in action.argv, "expected --use-compress-program, got %s" % action.argv)

    cmdline = action.argv[action.argv.index("--use-compress-program") + 1]
    asserts.true(env, cmdline.endswith(" --loud"), "compressor args must ride on the command line, got %r" % cmdline)
    asserts.true(env, "fake_compressor" in cmdline, "expected the program path in %r" % cmdline)

    # bsdtar spawns it from the execroot, so it has to be an action input.
    asserts.true(
        env,
        any([f.basename == "fake_compressor" for f in action.inputs.to_list()]),
        "the compressor binary must be an input of the tar action",
    )

    # The tier reaches a custom compressor the same way the rule attr does.
    _assert_tar_flags(env, "_branding.tar.lolz", ["--use-compress-program"])

    return analysistest.end(env)

custom_compressor_test = analysistest.make(_custom_compressor_impl)

def _oci_compressor_impl(ctx):
    env = analysistest.begin(ctx)

    # A custom compressor declaring an OCI extension is accepted without the
    # opt-in, and the layer still goes through --use-compress-program.
    _assert_tar_flags(env, "_default.tar.gz", ["--use-compress-program"])

    return analysistest.end(env)

oci_compressor_test = analysistest.make(_oci_compressor_impl)

def _expected_failure_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

expected_failure_test = analysistest.make(
    _expected_failure_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)
