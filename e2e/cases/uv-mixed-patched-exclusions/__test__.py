"""Verify a pre-build patch is reflected in the filtered Gazelle index."""

import sys
from pathlib import Path

assert "    patched_backend: markupsafe\n" in Path(sys.argv[1]).read_text()
