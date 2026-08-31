"""Assert an oci_image labels py_image_layer's tars as the layers they really are.

rules_oci derives a layer's `mediaType` and `diffid` by sniffing the archive's
magic: gzip and zstd are recognised, everything else falls through as an
uncompressed tar whose `diffid` is left as the *compressed* digest. That failure
is silent — the image builds and is invalid — so this walks the produced OCI
layout and checks both halves of the contract for every layer:

  * the layer's bytes really are the format its mediaType claims, and
  * a compressed layer's diff_id differs from its digest, i.e. rules_oci
    actually decompressed it to compute the uncompressed digest.

The first check is the one that catches this bug, and it has to read the blob:
a mislabelled bzip2 layer is indistinguishable from a genuine uncompressed tar
by metadata alone, because rules_oci writes `mediaType: ...tar` and leaves
`diff_id == digest` — exactly what an honest uncompressed layer looks like. The
manifest is self-consistent and simply wrong about the bytes.

Both run over every layer in the image, the base's included. The `--min` counts
are minimums rather than exact figures for the same reason: the base contributes
layers of its own, and how many is not this rule's business.
"""

import argparse
import json
import os
import sys
from typing import Any, NoReturn

# The three layer formats the OCI spec defines, by the name you pass to --min.
SUFFIX_BY_NAME = {"none": "", "gzip": "+gzip", "zstd": "+zstd"}
OCI_MEDIA_TYPES = frozenset(
    "application/vnd.oci.image.layer.v1.tar{}".format(suffix) for suffix in SUFFIX_BY_NAME.values()
)

# What the blob must actually start with, per declared compression:
# (human name, byte offset, magic). A POSIX tar carries "ustar" at 257.
LAYER_MAGIC = {
    "": ("an uncompressed tar", 257, b"ustar"),
    "+gzip": ("gzip", 0, b"\x1f\x8b"),
    "+zstd": ("zstd", 0, b"\x28\xb5\x2f\xfd"),
}


def fail(message: str) -> NoReturn:
    print("FAIL: {}".format(message), file=sys.stderr)
    sys.exit(1)


def blob_path(layout: str, digest: str) -> str:
    algorithm, _, hexdigest = digest.partition(":")
    path = os.path.join(layout, "blobs", algorithm, hexdigest)
    if not os.path.exists(path):
        fail("blob {} missing from the layout at {}".format(digest, layout))
    return path


def read_blob(layout: str, digest: str) -> Any:
    with open(blob_path(layout, digest), "rb") as handle:
        return json.load(handle)


def check_layer_bytes(layout: str, digest: str, suffix: str) -> None:
    """Assert the blob really is the format its mediaType claims."""
    name, offset, magic = LAYER_MAGIC[suffix]
    with open(blob_path(layout, digest), "rb") as handle:
        handle.seek(offset)
        head = handle.read(len(magic))
    if head != magic:
        fail(
            "layer {} is labelled {} but its bytes are not — expected {!r} at offset {}, "
            "got {!r}. rules_oci did not recognise this compression.".format(
                digest, name, magic, offset, head
            )
        )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    # --min=zstd:1 -- at least this many layers carry that compression. A
    # minimum rather than an exact count because the base image contributes
    # layers of its own, and how many is not this rule's business.
    parser.add_argument("--min", action="append", default=[])
    parser.add_argument("layout")
    args = parser.parse_args(argv)

    layout = args.layout
    if not os.path.isdir(layout):
        fail("{} is not an OCI layout directory".format(layout))

    with open(os.path.join(layout, "index.json"), "rb") as handle:
        index = json.load(handle)
    manifest = read_blob(layout, index["manifests"][0]["digest"])
    config = read_blob(layout, manifest["config"]["digest"])

    layers = manifest["layers"]
    diff_ids = config["rootfs"]["diff_ids"]
    if len(layers) != len(diff_ids):
        fail("{} layers but {} diff_ids".format(len(layers), len(diff_ids)))

    seen: dict[str, int] = {}
    for layer, diff_id in zip(layers, diff_ids):
        media_type = layer["mediaType"]
        suffix = media_type.partition("tar")[2]
        if media_type not in OCI_MEDIA_TYPES:
            fail("layer {} has media type {!r}, which is not an OCI layer format".format(layer["digest"], media_type))
        seen[suffix] = seen.get(suffix, 0) + 1
        check_layer_bytes(layout, layer["digest"], suffix)

        # An uncompressed layer is its own diff; a compressed one must have been
        # decompressed to get here, so the two digests cannot match.
        if suffix and diff_id == layer["digest"]:
            fail(
                "layer {} is {} but its diff_id equals the compressed digest — "
                "rules_oci did not recognise the compression".format(layer["digest"], media_type)
            )
        if not suffix and diff_id != layer["digest"]:
            fail("uncompressed layer {} has a diff_id of {}".format(layer["digest"], diff_id))

    for spec in args.min:
        name, _, count = spec.rpartition(":")
        if name not in SUFFIX_BY_NAME:
            fail("--min takes one of {}, got {!r}".format(sorted(SUFFIX_BY_NAME), name))
        found = seen.get(SUFFIX_BY_NAME[name], 0)
        if found < int(count):
            fail("expected at least {} {} layer(s), found {}".format(count, name, found))
        print("ok: {} {} layer(s), at least {} required".format(found, name, count))

    print("ok: all {} layers carry the bytes their mediaType claims, with matching diff_ids".format(len(layers)))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
