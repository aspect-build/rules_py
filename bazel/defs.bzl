load("@bazel_features_version//:version.bzl", bazel_version = "version")
load("@bazel_skylib//lib:versions.bzl", "versions")

# Quick and dirty way to render the bazelrc preset generation just incompatible
# on Bazel other than our baseline (7.X).
def incompatible_with(version):
    if versions.is_at_least(version, bazel_version):
        return ["@platforms//:incompatible"]
    else:
        return []
