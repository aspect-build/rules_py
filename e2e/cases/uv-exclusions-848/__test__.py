#!/usr/bin/env python3

"""Test that exclusion globs remove the expected installed files."""

import importlib
import importlib.metadata

import cowsay

output = cowsay.get_output_string("cow", "exclusions work!")
assert "exclusions work!" in output
print("cowsay functional: OK")

try:
    importlib.import_module("cowsay.tests.solutions")
except ModuleNotFoundError:
    pass
else:
    raise AssertionError("srcs_exclude_glob did not prevent importing cowsay.tests.solutions")
print("srcs_exclude_glob srcs: OK")

dist = importlib.metadata.distribution("cowsay")
assert dist.read_text("LICENSE.txt") is None, "data_exclude_glob did not remove LICENSE.txt"
print("data_exclude_glob data: OK")

main = importlib.import_module("cowsay.main")
assert main is not None, (
    "data_exclude_glob should not prevent importing cowsay.main because it is treated as srcs"
)
print("data_exclude_glob src preservation: OK")

metadata_text = dist.read_text("METADATA")
assert metadata_text is not None and "Name: cowsay" in metadata_text, (
    "srcs_exclude_glob should not remove dist-info/METADATA because it is treated as data"
)
print("srcs_exclude_glob data preservation: OK")

print("All exclusion tests passed.")
