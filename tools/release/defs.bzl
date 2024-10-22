"Make releases for platforms supported by rules_py"

load("@aspect_bazel_lib//lib:copy_file.bzl", "copy_file")
load("@aspect_bazel_lib//lib:transitions.bzl", "platform_transition_binary")
load("@aspect_bazel_lib//tools/release:hashes.bzl", "hashes")
load("@rules_rust//rust:defs.bzl", "rust_binary")

def _map_os_to_triple(os):
    if os == "linux":
        # TODO: when we produce musl-linked binaries, this should change to unknown-linux-musl
        return "unknown-linux-gnu"
    if os == "macos":
        return "apple-darwin"
    fail("unrecognized os", os)

# buildozer: disable=function-docstring
def multi_arch_rust_binary_release(name, bin_name, os, archs = ["aarch64", "x86_64"], visibility = None, **kwargs):
    outs = []
    actuals = {}
    for arch in archs:
        rust_binary(
            name = "{}_{}_{}_build".format(bin_name, os, arch),
            platform = "//tools/release:{}_{}".format(os, arch),
            target_compatible_with = ["@platforms//os:{}".format(os)],
            **kwargs
        )

        # Artifact naming follows typical Rust "triples" convention.
        artifact = "{}-{}-{}".format(bin_name, arch, _map_os_to_triple(os))
        outs.append(artifact)
        copy_file(
            name = "copy_{}_{}_{}".format(bin_name, os, arch),
            src = "{}_{}_{}_build".format(bin_name, os, arch),
            out = artifact,
            target_compatible_with = ["@platforms//os:{}".format(os)],
        )

        hash_file = "{}_{}_{}.sha256".format(bin_name, os, arch)
        outs.append(hash_file)
        hashes(
            name = hash_file,
            src = artifact,
            target_compatible_with = ["@platforms//os:{}".format(os)],
        )

    native.filegroup(
        name = name,
        srcs = outs,
        target_compatible_with = ["@platforms//os:{}".format(os)],
        tags = ["manual"],
        visibility = visibility,
    )
