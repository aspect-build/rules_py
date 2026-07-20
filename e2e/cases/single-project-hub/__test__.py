#!/usr/bin/env python3
"""Smoke test the public hub and its Gazelle manifest."""

from pathlib import Path
import sys

import cowsay

manifest = Path(sys.argv[1]).read_text()
assert "    cowsay: cowsay" in manifest, manifest
assert not any(
    line.startswith(("    wheel:", "    wheel.", "    packaging:", "    packaging."))
    for line in manifest.splitlines()
), manifest

cowsay.cow("single-project-hub")
