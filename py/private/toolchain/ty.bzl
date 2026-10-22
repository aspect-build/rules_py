"""Repository rule downloading a prebuilt ty for the default type checker toolchain."""

# TOOLCHAIN_PLATFORMS key -> upstream release triple.
TY_PLATFORMS = {
    "darwin_amd64": "x86_64-apple-darwin",
    "darwin_arm64": "aarch64-apple-darwin",
    "linux_amd64": "x86_64-unknown-linux-musl",
    "linux_arm64": "aarch64-unknown-linux-musl",
    "windows_amd64": "x86_64-pc-windows-msvc",
    "windows_arm64": "aarch64-pc-windows-msvc",
}

_BUILD = """\
load("@aspect_rules_py//py/private/toolchain:type_checker.bzl", "py_type_checker_toolchain")

py_type_checker_toolchain(
    name = "ty_toolchain",
    checker = "{binary}",
    visibility = ["//visibility:public"],
)
"""

def _ty_repository_impl(rctx):
    platform = rctx.attr.platform
    is_windows = platform.endswith("-windows-msvc")
    ext = "zip" if is_windows else "tar.gz"
    rctx.download_and_extract(
        url = "https://github.com/astral-sh/ty/releases/download/{v}/ty-{p}.{ext}".format(
            v = rctx.attr.version,
            p = platform,
            ext = ext,
        ),
        sha256 = rctx.attr.sha256,
        canonical_id = "ty-{}-{}".format(rctx.attr.version, platform),
        # Windows zips place `ty.exe` at the root; Unix tarballs nest it.
        stripPrefix = "" if is_windows else "ty-{}".format(platform),
    )
    rctx.file("BUILD.bazel", _BUILD.format(binary = "ty.exe" if is_windows else "ty"))
    return rctx.repo_metadata(reproducible = True)

ty_repository = repository_rule(
    implementation = _ty_repository_impl,
    doc = "Downloads a ty release binary and wraps it in a py_type_checker_toolchain.",
    attrs = {
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True, doc = "Upstream release triple."),
        "sha256": attr.string(mandatory = True),
    },
)
