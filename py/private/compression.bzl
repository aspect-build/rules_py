"""Compression codecs for `py_image_layer` layer tars.

Layer tars are written by bsdtar, so the usable set is libarchive's write-filter
set, mapped here onto bsdtar flags and file extensions. `py_layer_compressor`
covers everything else via `--use-compress-program`.

libarchive implements lzop and lrzip by shelling out to a same-named binary,
which a sandboxed action is not guaranteed to have; `py_layer_compressor` is
the hermetic answer there.

The OCI image spec only defines tar, gzip and zstd layers, and rules_oci sniffs
exactly those two magics — anything else is labelled an uncompressed tar and
gets the *compressed* digest as its `diffid`, which is a broken image rather
than a build error. So `oci` marks the codecs an image consumer can actually
read, and the rules refuse the rest unless `allow_non_oci_layers` says the tars
are headed somewhere other than an OCI image.
"""

PyLayerCompressorInfo = provider(
    doc = "A custom layer compressor: a program bsdtar pipes the archive through.",
    fields = {
        "args": "tuple[str] — arguments appended after the program path.",
        "executable": "File — the program bsdtar invokes via --use-compress-program.",
        "extension": "str — output file extension, e.g. '.tar.br'.",
        "files_to_run": "FilesToRunProvider — the program plus its runfiles, for the tar action's `tools`.",
    },
)

# flag: selects the write filter. filter: the `--options` module accepting
# `compression-level`, None when the filter has no level knob. oci: the OCI
# image spec defines a layer format for it.
ALGORITHMS = {
    "bzip2": struct(flag = "--bzip2", filter = "bzip2", ext = ".tar.bz2", min_level = 1, max_level = 9, oci = False),
    "compress": struct(flag = "--compress", filter = None, ext = ".tar.Z", min_level = 0, max_level = 0, oci = False),
    "gzip": struct(flag = "--gzip", filter = "gzip", ext = ".tar.gz", min_level = 0, max_level = 9, oci = True),
    "lrzip": struct(flag = "--lrzip", filter = "lrzip", ext = ".tar.lrz", min_level = 1, max_level = 9, oci = False),
    # lz4 rejects level 0 outright ("Undefined option"), unlike gzip/xz/lzma.
    "lz4": struct(flag = "--lz4", filter = "lz4", ext = ".tar.lz4", min_level = 1, max_level = 9, oci = False),
    "lzma": struct(flag = "--lzma", filter = "lzma", ext = ".tar.lzma", min_level = 0, max_level = 9, oci = False),
    "lzop": struct(flag = "--lzop", filter = "lzop", ext = ".tar.lzo", min_level = 1, max_level = 9, oci = False),
    "none": struct(flag = None, filter = None, ext = ".tar", min_level = 0, max_level = 0, oci = True),
    "xz": struct(flag = "--xz", filter = "xz", ext = ".tar.xz", min_level = 0, max_level = 9, oci = False),
    "zstd": struct(flag = "--zstd", filter = "zstd", ext = ".tar.zst", min_level = -131072, max_level = 22, oci = True),
}

SUPPORTED_ALGORITHMS = sorted(ALGORITHMS.keys())
OCI_ALGORITHMS = sorted([name for name, spec in ALGORITHMS.items() if spec.oci])

# A custom compressor declares what it emits through its extension; only these
# three land on a layer an OCI consumer can read.
_OCI_EXTENSIONS = {spec.ext: name for name, spec in ALGORITHMS.items() if spec.oci}

# libarchive's gzip filter stamps wall-clock into the header's MTIME field, so
# identical inputs would yield different layer digests. `!timestamp` zeroes it.
# No other write filter has an equivalent field.
_EXTRA_OPTIONS = {
    "gzip": ["gzip:!timestamp"],
}

DEFAULT_ALGORITHM = "gzip"
DEFAULT_LEVEL = "6"

def _is_integer(value):
    digits = value[1:] if value.startswith("-") else value
    return len(digits) > 0 and digits.isdigit()

def _attr_suffix(attr_path):
    """Parenthesized ` (py_layer_tier.compression["x"])` for an error message, or "" when unknown."""
    return " (%s)" % attr_path if attr_path else ""

def make_codec(algorithm, level, attr_path = ""):
    """Resolve a builtin bsdtar algorithm + level into a codec struct.

    Args:
        algorithm: One of `SUPPORTED_ALGORITHMS`.
        level: Compression level as a string, or "" to use libarchive's default.
        attr_path: The attribute the values came from, named in error messages,
            e.g. `py_layer_tier.compression["x"]`. Omit when there is no
            user-visible attribute to point at.

    Returns:
        A codec struct consumed by `codec_tar_args` / `codec_tools`.
    """
    spec = ALGORITHMS.get(algorithm, None)
    if spec == None:
        fail("unknown compression algorithm %r%s. Supported: %s. For anything else, " %
             (algorithm, _attr_suffix(attr_path), ", ".join(SUPPORTED_ALGORITHMS)) +
             "declare a py_layer_compressor and point `compressors` at it.")

    options = list(_EXTRA_OPTIONS.get(algorithm, []))
    if level:
        if not _is_integer(level):
            fail("compression level must be an integer, got %r%s" % (level, _attr_suffix(attr_path)))
        if spec.filter == None:
            fail("the %r compressor takes no compression level%s; drop the level or " %
                 (algorithm, _attr_suffix(attr_path)) + "pick an algorithm that has one.")
        as_int = int(level)
        if as_int < spec.min_level or as_int > spec.max_level:
            fail("compression level %s is out of range for %r%s: expected %d..%d" %
                 (level, algorithm, _attr_suffix(attr_path), spec.min_level, spec.max_level))
        options.append("{}:compression-level={}".format(spec.filter, level))

    return struct(
        algorithm = algorithm,
        flag = spec.flag,
        options = ",".join(options) if options else None,
        ext = spec.ext,
        oci_compatible = spec.oci,
        program = None,
        program_format = None,
        files_to_run = None,
    )

def codec_from_compressor(info):
    """Resolve a `PyLayerCompressorInfo` into a codec struct.

    Args:
        info: The `PyLayerCompressorInfo` of a `py_layer_compressor` target.

    Returns:
        A codec struct consumed by `codec_tar_args` / `codec_tools`.
    """
    suffix = "".join([" " + arg for arg in info.args])
    return struct(
        algorithm = "custom",
        flag = None,
        options = None,
        ext = info.extension,
        # The program's bytes are opaque to us; its declared extension is the
        # only claim we have about what an image consumer would find.
        oci_compatible = info.extension in _OCI_EXTENSIONS,
        program = info.executable,
        # bsdtar takes `program arg...` as one argv entry and splits it itself.
        program_format = "%s" + suffix,
        files_to_run = info.files_to_run,
    )

def check_oci_compatible(codec, group_name, attr_path, allowed):
    """Reject a codec no OCI image consumer can read, unless opted out of OCI.

    Args:
        codec: A codec struct from `make_codec` or `codec_from_compressor`.
        group_name: The layer group the codec was selected for, named in the error.
        attr_path: The attribute that selected it, e.g. `py_layer_tier.compression`.
        allowed: True when the target set `allow_non_oci_layers`.
    """
    if codec.oci_compatible or allowed:
        return
    if codec.program != None:
        detail = ("a py_layer_compressor declaring extension %r" % codec.ext)
    else:
        detail = "%r" % codec.algorithm
    fail(("group %r uses %s, which is not an OCI layer format. The spec defines " +
          "only %s, and rules_oci labels anything else an uncompressed tar with " +
          "the compressed digest as its diffid — the layer builds and the image " +
          "is invalid.\n\nUse one of %s in %s, or set allow_non_oci_layers = True " +
          "if these tars are not going into an OCI image.") %
         (group_name, detail, ", ".join(OCI_ALGORITHMS), ", ".join(OCI_ALGORITHMS), attr_path))

def codec_tar_args(codec, tar_args):
    """Append the codec's filter selection to a bsdtar `--create` command line.

    Args:
        codec: A codec struct from `make_codec` or `codec_from_compressor`.
        tar_args: The `ctx.actions.args()` object being built for bsdtar.
    """
    if codec.program != None:
        tar_args.add("--use-compress-program")
        tar_args.add(codec.program, format = codec.program_format)
        return
    if codec.flag != None:
        tar_args.add(codec.flag)
    if codec.options != None:
        tar_args.add("--options", codec.options)

def codec_tools(codec):
    """Extra `tools` the tar action needs for this codec.

    Args:
        codec: A codec struct from `make_codec` or `codec_from_compressor`.

    Returns:
        A list to pass as `ctx.actions.run(tools = ...)`; empty for builtin filters.
    """
    return [codec.files_to_run] if codec.files_to_run != None else []

def parse_compression(value, attr_path):
    """Validate a `[algorithm]` / `[algorithm, level]` attr value into a codec.

    Args:
        value: The attribute value as written in the BUILD file.
        attr_path: The attribute `value` came from, named in error messages,
            e.g. `py_layer_tier.compression["x"]`.

    Returns:
        A codec struct consumed by `codec_tar_args` / `codec_tools`.
    """
    if len(value) == 0 or len(value) > 2:
        fail("%s must be [algorithm] or [algorithm, level], got %r" % (attr_path, value))
    return make_codec(value[0], value[1] if len(value) == 2 else "", attr_path)

def _py_layer_compressor_impl(ctx):
    files_to_run = ctx.attr.tool[DefaultInfo].files_to_run
    if files_to_run == None or files_to_run.executable == None:
        fail("py_layer_compressor.tool must be an executable target, got %s" % ctx.attr.tool.label)

    if not ctx.attr.extension.startswith("."):
        fail("py_layer_compressor.extension must start with '.', got %r" % ctx.attr.extension)

    for arg in ctx.attr.args:
        # libarchive splits the command line on whitespace before exec'ing, so
        # anything needing quoting has to live in a wrapper script instead.
        if arg != arg.strip() or " " in arg or "\t" in arg or '"' in arg or "'" in arg:
            fail("py_layer_compressor.args entries must be single whitespace-free " +
                 "tokens without quotes, got %r. Wrap the program in a shell script." % arg)
        if "%" in arg:
            fail("py_layer_compressor.args entries must not contain '%%', got %r" % arg)

    return [
        PyLayerCompressorInfo(
            executable = files_to_run.executable,
            files_to_run = files_to_run,
            args = tuple(ctx.attr.args),
            extension = ctx.attr.extension,
        ),
        DefaultInfo(files = depset([files_to_run.executable])),
    ]

py_layer_compressor = rule(
    implementation = _py_layer_compressor_impl,
    doc = """A user-supplied program that compresses `py_image_layer` layer tars.

bsdtar pipes the archive through `tool` (via `--use-compress-program`), so any
program that reads an uncompressed stream on stdin and writes the compressed
stream to stdout works — including compressors libarchive has no filter for.

```starlark
py_layer_compressor(
    name = "pigz",
    tool = "//tools:pigz",
    args = ["-11"],
    extension = ".tar.gz",
)

py_layer_tier(
    name = "tier",
    groups = {"@pip//torch": "heavy"},
    compressors = {":pigz": "heavy"},
)
```

`extension` is the only claim available about the program's output, so it also
decides whether the layer is OCI-valid: anything but `.tar`, `.tar.gz` or
`.tar.zst` needs `allow_non_oci_layers = True` on the tier or rule.

The program runs inside the tar action, so prefer a Bazel-built binary or a
`sh_binary` wrapper over something assumed to be on the host's PATH.
""",
    attrs = {
        "args": attr.string_list(
            default = [],
            doc = ("Arguments passed after the program path. Each entry must be a single " +
                   "whitespace-free token — bsdtar splits the command line itself."),
        ),
        "extension": attr.string(
            mandatory = True,
            doc = ("Extension for tars this compressor produces, e.g. '.tar.gz'. Must start " +
                   "with '.'. Also declares OCI validity: only '.tar', '.tar.gz' and " +
                   "'.tar.zst' are layer formats an image consumer can read."),
        ),
        "tool": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "The compressor program. Reads stdin, writes compressed bytes to stdout.",
        ),
    },
    provides = [PyLayerCompressorInfo],
)
