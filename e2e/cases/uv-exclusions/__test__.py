#!/usr/bin/env python3

"""Verify that wheel filtering preserves runtime behavior without retaining excluded files."""

import importlib.metadata
from pathlib import Path

import cowsay
from google.api import annotations_pb2, http_pb2

package = Path(cowsay.__file__).parent
assert not (package / "tests").exists()
assert not (package / "nested" / "tests").exists()
assert not list(package.rglob("test_*.pyc"))
assert list((package / "__pycache__").glob("main.*.pyc"))

distribution = importlib.metadata.distribution("cowsay")
assert distribution.read_text("LICENSE.txt") is None
assert "Name: cowsay" in distribution.read_text("METADATA")
assert distribution.files is not None
assert not any(
    str(path).endswith("LICENSE.txt") or "/tests/" in str(path)
    for path in distribution.files
)

assert "exclusions work!" in cowsay.get_output_string("cow", "exclusions work!")

google = Path(annotations_pb2.__file__).parents[1]
assert not list(google.rglob("*.proto"))
assert annotations_pb2.DESCRIPTOR.name == "google/api/annotations.proto"
assert http_pb2.DESCRIPTOR.name == "google/api/http.proto"

distribution = importlib.metadata.distribution("googleapis-common-protos")
assert distribution.files is not None
assert not any(str(path).endswith(".proto") for path in distribution.files)
assert all(distribution.locate_file(path).exists() for path in distribution.files)
