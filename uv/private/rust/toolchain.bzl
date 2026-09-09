"""The Rust toolchain rules_py hands to PEP 517 builds of Rust sdists."""

RUST_TOOLCHAIN_TYPE = "@aspect_rules_py//uv/private/rust:toolchain_type"

def _root_of(files, marker):
    """Repository root shared by `files`, from any path containing `marker`."""
    for f in files.to_list():
        idx = f.path.find(marker)
        if idx != -1:
            return f.path[:idx]
    return None

def _rust_pep517_toolchain_impl(ctx):
    rustc = ctx.file.rustc
    sysroot = rustc.path[:-len("/bin/rustc")]
    target_std_roots = []
    transitive = [ctx.attr.sysroot_files[DefaultInfo].files]
    for std in ctx.attr.target_std:
        files = std[DefaultInfo].files
        transitive.append(files)
        root = _root_of(files, "/lib/rustlib/")
        if root:
            target_std_roots.append(root)
    return [platform_common.ToolchainInfo(
        rustc = rustc,
        cargo = ctx.file.cargo,
        sysroot = sysroot,
        target_std_roots = target_std_roots,
        exec_triple = ctx.attr.exec_triple,
        target_triples = ctx.attr.target_triples,
        all_files = depset(transitive = transitive),
    )]

rust_pep517_toolchain = rule(
    implementation = _rust_pep517_toolchain_impl,
    doc = """A Rust toolchain for one (exec platform, target platform) pair.

`sysroot_files` is the exec platform's complete sysroot (rustc, cargo, its own
std); `target_std` holds the target platform's rust-std trees, one per libc on
Linux. The build helper passes the sysroot to rustc explicitly and, under
cross, overlays the target std onto it.""",
    attrs = {
        "rustc": attr.label(allow_single_file = True, mandatory = True),
        "cargo": attr.label(allow_single_file = True, mandatory = True),
        "sysroot_files": attr.label(mandatory = True),
        "target_std": attr.label_list(),
        "exec_triple": attr.string(mandatory = True),
        "target_triples": attr.string_list(mandatory = True),
    },
)
