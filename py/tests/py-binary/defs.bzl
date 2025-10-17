load("@bazel_skylib//lib:versions.bzl", "versions")
load("@bazel_features_version//:version.bzl", bazel_version = "version")

def munge(label):
    if versions.is_at_least("8.0.0", bazel_version):
        return label
    else:
        return label.replace("+", "~")
