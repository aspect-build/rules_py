"""Regression test for #1118: xds-protos ships opentelemetry/__init__.py
(empty, legacy namespace stub) while opentelemetry-sdk treats `opentelemetry`
as a PEP 420 namespace. Without the fix the regular-package claim wins the
top-level symlink and opentelemetry.sdk.* is unreachable.
"""

import os
import sysconfig


def test_sdk_importable():
    from opentelemetry.sdk.resources import Resource

    assert Resource is not None


def test_merged_layout():
    site_packages = sysconfig.get_paths()["purelib"]
    otel_dir = os.path.join(site_packages, "opentelemetry")

    assert os.path.isdir(otel_dir), (
        f"site-packages has no concrete opentelemetry/ directory at {otel_dir}"
    )

    # xds-protos ships an empty __init__.py (legacy namespace stub).
    init_py = os.path.join(otel_dir, "__init__.py")
    assert os.path.isfile(init_py), (
        f"opentelemetry/__init__.py missing — xds-protos content not merged"
    )
    assert os.path.getsize(init_py) == 0, (
        f"opentelemetry/__init__.py should be 0 bytes (xds-protos stub), "
        f"got {os.path.getsize(init_py)}"
    )

    # opentelemetry-sdk contributes opentelemetry/sdk/ into the merged dir.
    sdk_dir = os.path.join(otel_dir, "sdk")
    assert os.path.isdir(sdk_dir), (
        f"opentelemetry/sdk/ missing — PySiteMerge may not have run. "
        f"opentelemetry/ holds: {sorted(os.listdir(otel_dir))}"
    )


if __name__ == "__main__":
    test_sdk_importable()
    test_merged_layout()
    print("PASS")
