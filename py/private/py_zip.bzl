def _calculate_runfiles_dir(default_info):
    manifest = default_info.files_to_run.runfiles_manifest

    # Newer versions of Bazel put the manifest besides the runfiles with the suffix .runfiles_manifest.
    # For example, the runfiles directory is named my_binary.runfiles then the manifest is beside the
    # runfiles directory and named my_binary.runfiles_manifest
    # Older versions of Bazel put the manifest file named MANIFEST in the runfiles directory
    # See similar logic:
    # https://github.com/aspect-build/rules_js/blob/c50bd3f797c501fb229cf9ab58e0e4fc11464a2f/js/private/bash.bzl#L63
    if manifest.short_path.endswith("_manifest") or manifest.short_path.endswith("/MANIFEST"):
        # Trim last 9 characters, as that's the length in both cases
        return manifest.short_path[:-9]
    fail("manifest path {} seems malformed".format(manifest.short_path))


def build_python_zip(ctx, output):
    pass


ZIP_TOOLCHAIN = "@aspect_bazel_lib//lib:tar_toolchain_type"