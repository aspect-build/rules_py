#!/usr/bin/env python3

"""Verify that wheel filtering preserves runtime behavior without retaining excluded files."""

import hashlib
import importlib.metadata
from base64 import urlsafe_b64encode
from pathlib import Path

import cowsay
from cowsay import main
from cowsay.retained import PATCH_SENTINEL
from google.api import annotations_pb2, http_pb2

package = Path(cowsay.__file__).parent
assert not (package / "tests").exists()
assert not (package / "nested" / "tests").exists()
assert not list(package.rglob("test_*.pyc"))
assert list((package / "__pycache__").glob("main.*.pyc"))

cowsay_distribution = importlib.metadata.distribution("cowsay")
assert cowsay_distribution.read_text("LICENSE.txt") is None
assert "Name: cowsay" in cowsay_distribution.read_text("METADATA")
assert cowsay_distribution.files is not None
recorded = {str(path) for path in cowsay_distribution.files}
assert "cowsay/main.py" in recorded
assert "cowsay/retained.py" in recorded
assert "../../../share/cowsay/retained.txt" in recorded
assert not any(str(path).endswith(".pyc") for path in cowsay_distribution.files)
assert not any(
    str(path).endswith("LICENSE.txt") or "/tests/" in str(path)
    for path in cowsay_distribution.files
)

assert main.__version__ == "6.1"
assert PATCH_SENTINEL == "retained patched module"
assert "exclusions work!" in cowsay.get_output_string("cow", "exclusions work!")

google = Path(annotations_pb2.__file__).parents[1]
assert not list(google.rglob("*.proto"))
assert annotations_pb2.DESCRIPTOR.name == "google/api/annotations.proto"
assert http_pb2.DESCRIPTOR.name == "google/api/http.proto"

distribution = importlib.metadata.distribution("googleapis-common-protos")
assert distribution.files is not None
assert not any(str(path).endswith(".proto") for path in distribution.files)

for installed_distribution, installed_package in [
    (cowsay_distribution, package),
    (distribution, google),
]:
    for path in installed_distribution.files:
        installed = installed_package.resolve().parent / path
        assert installed.is_file(), path
        if str(path).endswith(".dist-info/RECORD"):
            assert path.size is None, path
            assert path.hash is None, path
            continue
        assert path.size is not None, path
        assert installed.stat().st_size == path.size, path
        if path.hash is not None:
            assert path.hash.mode == "sha256", path
            digest = urlsafe_b64encode(hashlib.sha256(installed.read_bytes()).digest())
            assert digest.decode().rstrip("=") == path.hash.value, path
