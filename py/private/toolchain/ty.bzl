"""Repository rule downloading a prebuilt ty for the default type checker toolchain."""

# Upstream release checksums, from each release's `sha256.sum`.
TY_VERSIONS = {
    "0.0.84": {
        "aarch64-apple-darwin": "c65c09f27bcef726c0b043dcee8d0f1e578bd1936799e5bc447235cbc3e19d91",
        "aarch64-pc-windows-msvc": "5310f17fc594e29e525ccd0eaa27b719b2af2a88ec7be38092af7036eaab5235",
        "aarch64-unknown-linux-musl": "e0f1cbe08fad84a164dbac8945730a349d506836f185afdb927e16395136d091",
        "x86_64-apple-darwin": "3891e5509d306721cee4dd4e69b94535dbd96371af7ec3b734ee65f25b167ae4",
        "x86_64-pc-windows-msvc": "e4b3c7cd30ff8b4ee4c2a62621f293341ad3c89fb3e7c6e4d2686150a4dbcf08",
        "x86_64-unknown-linux-musl": "da32bd4cbfe124f1df974e78cc163037c5d4b12ceec532b7ed785b5b74a76cd1",
    },
}

DEFAULT_TY_VERSION = "0.0.84"

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
    args = [
        "check",
        "--no-progress",
        "--output-format=concise",
        "--color=never",
        # Only errors fail the build. Rules can be raised to errors in a
        # configuration file.
        "--exit-zero-on-warning",
        # Keeps ty from discovering a pyproject.toml or .venv by walking up
        # from the execroot, which only happens outside the sandbox.
        "--project={{scratch}}",
        # Without this, ty falls back to the site-packages of whichever
        # `python` is on PATH.
        "--python={{empty_python_prefix}}",
    ],
    config_flag = "--config-file",
    python_version_flag = "--python-version",
    search_path_flag = "--extra-search-path",
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
