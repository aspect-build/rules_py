"""Public surface of the PEP 517 sdist-to-wheel rules."""

load(":pep517_native_whl.bzl", _pep517_native_whl = "pep517_native_whl")
load(":pep517_whl.bzl", _pep517_whl = "pep517_whl")

pep517_whl = _pep517_whl
pep517_native_whl = _pep517_native_whl
