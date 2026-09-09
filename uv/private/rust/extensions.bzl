"""Module extension provisioning rules_py's own Rust toolchain for sdist builds.

Rust sdists (maturin, setuptools-rust) need cargo, rustc and a std for the
exec and target platforms. rules_py fetches the official Rust dist archives
itself, the way it fetches Python interpreters and uv, so no ruleset has to
be added or registered for a Rust package in the lock to build.
"""

load("//uv/private/rust:repositories.bzl", "rust_host_repository", "rust_hub_repository", "rust_std_repository")
load("//uv/private/rust:versions.bzl", "LATEST_RUST_VERSION", "RUST_HOST_TRIPLES", "RUST_TARGETS", "RUST_VERSIONS")

_HUB = "rules_py_rust_toolchains"
_PREFIX = "rules_py_rust_"

def _rust_tools_impl(module_ctx):
    version = LATEST_RUST_VERSION
    sha256s = {}
    for mod in module_ctx.modules:
        for tc in mod.tags.toolchain:
            if mod.is_root:
                version = tc.version or version
                sha256s = dict(tc.sha256s)
    hashes = dict(RUST_VERSIONS.get(version, {}))
    hashes.update(sha256s)

    def sha(component, triple):
        key = "{}-{}".format(component, triple)
        if key not in hashes:
            fail("rust_tools.toolchain(version = \"{}\"): no sha256 pinned for {}; pass it in `sha256s`.".format(version, key))
        return hashes[key]

    for host in RUST_HOST_TRIPLES:
        rust_host_repository(
            name = _PREFIX + "host_" + host.replace("-", "_"),
            version = version,
            triple = host,
            rustc_sha256 = sha("rustc", host),
            cargo_sha256 = sha("cargo", host),
            std_sha256 = sha("rust-std", host),
        )
    std_triples = {t: None for triples in RUST_TARGETS.values() for t in triples}
    for triple in std_triples:
        rust_std_repository(
            name = _PREFIX + "std_" + triple.replace("-", "_"),
            version = version,
            triple = triple,
            sha256 = sha("rust-std", triple),
        )
    rust_hub_repository(
        name = _HUB,
        repo_prefix = _PREFIX,
        host_triples = RUST_HOST_TRIPLES,
        targets_json = json.encode({"{}/{}".format(os, cpu): triples for (os, cpu), triples in RUST_TARGETS.items()}),
    )
    return module_ctx.extension_metadata(reproducible = True)

_toolchain_tag = tag_class(
    attrs = {
        "version": attr.string(
            doc = "Rust release to use for sdist builds (e.g. '1.90.0'). Defaults to the latest version pinned in aspect_rules_py. Only the root module's choice applies.",
        ),
        "sha256s": attr.string_dict(
            doc = "`<component>-<triple>` -> sha256 of the dist archive, for versions aspect_rules_py does not pin.",
        ),
    },
    doc = "Selects the Rust release rules_py fetches for building Rust sdists.",
)

rust_tools = module_extension(
    implementation = _rust_tools_impl,
    tag_classes = {"toolchain": _toolchain_tag},
    doc = "Fetches the Rust toolchain rules_py uses to build Rust sdists and publishes `@rules_py_rust_toolchains`.",
)
