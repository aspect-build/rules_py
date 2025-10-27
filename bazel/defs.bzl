"""
Helpers.

Mostly for working around Bazel migration issues.
"""

load("@bazel_features_version//:version.bzl", bazel_version = "version")
load("@bazel_skylib//lib:versions.bzl", "versions")

# Quick and dirty way to render the bazelrc preset generation just incompatible
# on Bazel other than our baseline (7.X).
def incompatible_with(version, default = []):
    """Incompatibility with Bazel.

    A hacky way to mark a target (or toolchain) as incompatible with the Bazel
    engine itself.

    Args:
      version (str): The version Bazle to decide incompatibility with.
      default (list): The default compatibility list.

    Returns:
      The default compatibility list, or incompatible.

    """

    if versions.is_at_least(version, bazel_version):
        return ["@platforms//:incompatible"]
    else:
        return default

def munge(label):
    """Munge external labels from 7->8.

    Under Bazel 8, + is used as the external repo munging character instead of
    ~, which was used in 6 and 7. Re-munge 7-style labels to be 8 compatible
    when testing on later Bazel versions. Migration helper.

    Args:
      label (str): A label string to munge

    Returns:
      The string, re-munged as needed

    """

    if versions.is_at_least("8.0.0", bazel_version):
        return label
    else:
        return label.replace("+", "~")
