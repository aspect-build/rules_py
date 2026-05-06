"""Smoke test the synthesis-fallback resolution actually delivered pytest."""

import pytest


def test_pytest_resolved():
    assert pytest.__version__
