"""A Bazel module extension for downloading and registering UV binaries."""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("//uv/private/toolchain:repositories.bzl", "uv_hub_repository", "uv_repository")
load("//uv/private/toolchain:versions.bzl", "UV_VERSIONS")

LATEST_UV_VERSION = UV_VERSIONS.keys()[-1]

def _uv_bin_impl(module_ctx):
    # Collect per-hub config, keyed by the `name` attr (default "uv"). Tags
    # sharing a name must agree on all attrs.
    hubs = {}
    for mod in module_ctx.modules:
        for tc in mod.tags.toolchain:
            cfg = struct(
                version = tc.version,
                urls = list(tc.urls),
                sha256s = dict(tc.sha256s),
                strip_prefix = tc.strip_prefix,
            )
            existing = hubs.get(tc.name)
            if existing != None and (
                existing.version != cfg.version or
                existing.urls != cfg.urls or
                existing.sha256s != cfg.sha256s or
                existing.strip_prefix != cfg.strip_prefix
            ):
                fail(
                    "Conflicting uv_bin.toolchain(name = \"{}\") declarations. ".format(tc.name) +
                    "All tags sharing a name must agree on version, urls, sha256s, and strip_prefix.",
                )
            hubs[tc.name] = cfg

    for hub_name, cfg in hubs.items():
        hashes = dict(UV_VERSIONS.get(cfg.version, {}))
        hashes.update(cfg.sha256s)
        if not hashes:
            fail(
                "uv_bin.toolchain(name = \"{}\", version = \"{}\") is not pinned in aspect_rules_py ".format(hub_name, cfg.version) +
                "and has no `sha256s` entries. Supply `sha256s` with at least " +
                "one platform (value may be empty string for non-reproducible fetches).",
            )

        repo_prefix = "{}_".format(hub_name)
        for platform, sha256 in hashes.items():
            ext = "zip" if platform.endswith("-windows-msvc") else "tar.gz"
            urls = [
                tmpl.format(version = cfg.version, platform = platform, ext = ext)
                for tmpl in cfg.urls
            ]
            strip_prefix = cfg.strip_prefix.format(version = cfg.version, platform = platform) if cfg.strip_prefix else ""
            uv_repository(
                name = "{}{}".format(repo_prefix, platform.replace("-", "_")),
                version = cfg.version,
                platform = platform,
                sha256 = sha256,
                urls = urls,
                strip_prefix = strip_prefix,
            )

        uv_hub_repository(
            name = hub_name,
            version = cfg.version,
            platforms = hashes.keys(),
            repo_prefix = repo_prefix,
        )

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return module_ctx.extension_metadata(reproducible = True)

_toolchain_tag = tag_class(
    attrs = {
        "name": attr.string(
            default = "uv",
            doc = "Name of the hub repo (e.g. `@uv`). Set to a distinct value to publish an additional hub alongside the default.",
        ),
        "version": attr.string(
            default = LATEST_UV_VERSION,
            doc = "UV version to download (e.g. '0.11.6'). Defaults to the latest version known to aspect_rules_py.",
        ),
        "urls": attr.string_list(
            doc = "Download URL templates. Each entry is a format string with " +
                  "'{version}', '{platform}', and '{ext}' placeholders (ext is " +
                  "'tar.gz' on Unix, 'zip' on Windows). URLs are tried in order. " +
                  "When omitted, defaults to the upstream GitHub release URL.",
        ),
        "sha256s": attr.string_dict(
            doc = "Map of platform triple to SHA256 of the UV release archive. " +
                  "Overrides (or supplies, for unpinned versions) the hashes that " +
                  "ship with aspect_rules_py. Use this when combining `version` " +
                  "with `urls` to point at a custom build or mirror.",
        ),
        "strip_prefix": attr.string(
            doc = "Template for the archive's top-level directory, with " +
                  "'{version}' and '{platform}' placeholders. Defaults to " +
                  "the upstream layout (`uv-{platform}` on Unix, no prefix " +
                  "on Windows). Override when pointing at a build whose " +
                  "tarball uses a different naming convention.",
        ),
    },
    doc = "Configures the UV toolchain to download and register.",
)

uv_bin = module_extension(
    implementation = _uv_bin_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
    },
    doc = "Downloads UV binaries and registers `@uv//:all` toolchains.",
)
