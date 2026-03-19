"""Regression test for cross-repo pytest_main behavior (#867).

Validates that pytest_main=True on py_test works cross-repo: the shared
main lives in @aspect_rules_py while test sources live in the consumer.
Test discovery uses the .pytest_paths args file rather than autodiscovery.
"""

import os


def test_paths_file_exists():
    """The pytest_paths args file should be present in runfiles."""
    target = os.environ.get("BAZEL_TARGET", "")
    target_name = os.environ.get("BAZEL_TARGET_NAME", "")
    package = target.split(":")[0].lstrip("/")
    paths_file = os.path.join(package, target_name + ".pytest_paths")
    assert os.path.isfile(paths_file), f"Expected {paths_file} to exist (cwd={os.getcwd()})"

    with open(paths_file) as f:
        dirs = [line.strip() for line in f if line.strip()]
    assert len(dirs) > 0, "Expected at least one search directory"
    assert any("pytest-main-867" in d for d in dirs), (
        f"Expected a dir containing 'pytest-main-867', got: {dirs}"
    )
