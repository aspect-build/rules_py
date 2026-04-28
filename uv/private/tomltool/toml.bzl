"""Decode a TOML file to a Starlark dict via the prebuilt `toml2json` binary."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")

def _decode_file(ctx, content_path):
    ctx.watch(content_path)

    out = ctx.execute([
        Label("@toml2json_%s//file:downloaded" % repo_utils.platform(ctx)),
        content_path,
    ])
    if out.return_code == 0:
        return json.decode(out.stdout)

    fail("Unable to decode TOML file %s" % content_path)

toml = struct(
    decode_file = _decode_file,
)
