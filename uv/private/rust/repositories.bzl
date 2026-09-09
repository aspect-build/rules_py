"""Repository rules materializing a Rust toolchain for PEP 517 builds.

A host repository is a complete rustup-style sysroot for one exec platform:
rustc, cargo and that platform's rust-std, extracted into one tree. Std
repositories hold one target platform's rust-std; the helper overlays them
onto the host sysroot for cross builds, the way rustup keeps several targets
side by side.
"""

load(":versions.bzl", "rust_archive_prefix", "rust_archive_url")

def _download(rctx, component, triple, sha256):
    rctx.download_and_extract(
        url = rust_archive_url(component, rctx.attr.version, triple),
        sha256 = sha256,
        canonical_id = "{}-{}-{}".format(component, rctx.attr.version, triple),
        stripPrefix = rust_archive_prefix(component, rctx.attr.version, triple),
    )

def _repo_metadata(rctx):
    # Support bazel <v8.3 by returning None if repo_metadata is not defined
    if not hasattr(rctx, "repo_metadata"):
        return None
    return rctx.repo_metadata(reproducible = True)

def _rust_host_repository_impl(rctx):
    triple = rctx.attr.triple
    _download(rctx, "rustc", triple, rctx.attr.rustc_sha256)
    _download(rctx, "cargo", triple, rctx.attr.cargo_sha256)
    _download(rctx, "rust-std", triple, rctx.attr.std_sha256)
    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files([
    "bin/rustc",
    "bin/cargo",
])

# The whole sysroot the build action needs on disk: drivers, shared libs and
# the host's std. Docs and license files stay out of the action inputs.
filegroup(
    name = "sysroot",
    srcs = glob(
        [
            "bin/**",
            "lib/**",
            "libexec/**",
        ],
        exclude = ["lib/rustlib/**/analysis/**"],
    ),
)
""")
    return _repo_metadata(rctx)

rust_host_repository = repository_rule(
    implementation = _rust_host_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "triple": attr.string(mandatory = True),
        "rustc_sha256": attr.string(mandatory = True),
        "cargo_sha256": attr.string(mandatory = True),
        "std_sha256": attr.string(mandatory = True),
    },
)

def _rust_std_repository_impl(rctx):
    _download(rctx, "rust-std", rctx.attr.triple, rctx.attr.sha256)
    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

filegroup(
    name = "std",
    srcs = glob(["lib/**"]),
)
""")
    return _repo_metadata(rctx)

rust_std_repository = repository_rule(
    implementation = _rust_std_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "triple": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
    },
)

def _rust_hub_repository_impl(rctx):
    """One toolchain per (exec platform, target platform) pair."""
    targets = json.decode(rctx.attr.targets_json)
    lines = [
        'load("@aspect_rules_py//uv/private/rust:toolchain.bzl", "rust_pep517_toolchain")',
        'load("@aspect_rules_py//uv/private/rust:versions.bzl", "triple_constraints")',
        "",
        'package(default_visibility = ["//visibility:public"])',
    ]
    for host in rctx.attr.host_triples:
        host_repo = rctx.attr.repo_prefix + "host_" + host.replace("-", "_")
        for target_key, std_triples in targets.items():
            os, cpu = target_key.split("/")
            name = "{}__{}_{}".format(host.replace("-", "_"), os, cpu)
            std_labels = ['"@{}std_{}//:std"'.format(rctx.attr.repo_prefix, t.replace("-", "_")) for t in std_triples]
            lines.append("""
rust_pep517_toolchain(
    name = "{name}",
    cargo = "@{host_repo}//:bin/cargo",
    exec_triple = "{host}",
    rustc = "@{host_repo}//:bin/rustc",
    sysroot_files = "@{host_repo}//:sysroot",
    target_std = [{std_labels}],
    target_triples = {std_triples},
)

toolchain(
    name = "{name}_toolchain",
    exec_compatible_with = triple_constraints("{host}"),
    target_compatible_with = [
        "@platforms//os:{os}",
        "@platforms//cpu:{cpu}",
    ],
    toolchain = ":{name}",
    toolchain_type = "@aspect_rules_py//uv/private/rust:toolchain_type",
)""".format(
                name = name,
                host = host,
                host_repo = host_repo,
                std_labels = ", ".join(std_labels),
                std_triples = repr(std_triples),
                os = os,
                cpu = cpu,
            ))
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    return _repo_metadata(rctx)

rust_hub_repository = repository_rule(
    implementation = _rust_hub_repository_impl,
    attrs = {
        "repo_prefix": attr.string(mandatory = True),
        "host_triples": attr.string_list(mandatory = True),
        "targets_json": attr.string(mandatory = True, doc = "JSON: \"os/cpu\" -> [rust-std triples]."),
    },
)
