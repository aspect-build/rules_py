"""Release rule for a rust binary"""

load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@rules_pkg//pkg:mappings.bzl", "pkg_attributes", "pkg_files")
load("@rules_pkg//pkg:pkg.bzl", "pkg_tar", "pkg_zip")
load("//bazel/release:hashes.bzl", "hashes")

TARGET_TRIPLES = [
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
    "x86_64-apple-darwin",
    "aarch64-apple-darwin",
]

def multi_platform_rust_binaries(name, target, target_triples = TARGET_TRIPLES, prefix = "", pkg_type = "zip", **kwargs):
    """The multi_platform_rust_binaries macro creates a filegroup containing rust binaries that are ready for release.

    Args:
        name: The name of the filegroup containing all rust targets produced by this macro.
        target: rust_binary that releases will be created for.
        target_triples: Map of target triples to the target platform to build for.
        prefix: An optional prefix added to the output rust binary file name.
        pkg_type: The packaging type that the {name}.packaged target outputs, can be one of 'zip' or 'tar'.
        **kwargs: All other args, forwarded to the output filegroups.
    """

    mac_bins = []
    linux_bins = []

    mac_pkged = []
    linux_pkged = []

    bin = Label(target).name
    pkg_rule = pkg_zip if pkg_type == "zip" else pkg_tar

    for target_triple in target_triples:
        transition_build = "{}_{}_build".format(bin, target_triple)
        platform_transition_filegroup(
            name = transition_build,
            srcs = [target],
            target_platform = "@rules_rs//rs/experimental/platforms:" + target_triple,
            tags = ["release"],
        )

        copy_name = "{}{}_{}".format(prefix, bin, target_triple)
        copy_file(
            name = "{}_copy".format(copy_name),
            src = transition_build,
            out = copy_name,
            tags = ["release"],
        )

        bin_sha256 = "{}_bin_hash".format(copy_name)
        hashes(
            name = bin_sha256,
            src = copy_name,
            tags = ["release"],
        )

        pkged_files = "{}{}_{}_pkged_files".format(prefix, bin, target_triple)
        pkg_files(
            name = pkged_files,
            srcs = [copy_name],
            renames = {copy_name: bin},
            attributes = pkg_attributes(mode = "0744"),
            strip_prefix = "/",
            tags = ["release"],
        )

        pkged = "{}{}_{}_packed".format(prefix, bin, target_triple)
        pkg_rule(
            name = pkged,
            srcs = [
                pkged_files,
            ],
            out = "{}.{}".format(copy_name, pkg_type),
            # Why is -1 not the default :/
            # This also sets the modified time in UTC.
            stamp = -1,
            tags = ["release"],
        )

        pkged_sha256 = "{}_pkged_hash".format(copy_name)
        hashes(
            name = pkged_sha256,
            src = pkged,
            tags = ["release"],
        )

        bin_outs = [copy_name, bin_sha256]
        pkged_outs = [pkged, pkged_sha256]
        if "linux" in target_triple:
            linux_bins.extend(bin_outs)
            linux_pkged.extend(pkged_outs)
        else:
            mac_bins.extend(bin_outs)
            mac_pkged.extend(pkged_outs)

    native.filegroup(
        name = name,
        srcs = linux_bins + mac_bins,
        tags = kwargs.get("tags", []) + ["release"],
        visibility = kwargs.get("visibility", []),
    )

    native.filegroup(
        name = "{}.packaged".format(name),
        srcs = linux_pkged + mac_pkged,
        tags = kwargs.get("tags", []) + ["release"],
        visibility = kwargs.get("visibility", []),
    )
