"""Verify Gazelle indexes a filtered platform wheel and its source fallback."""

import sys
from pathlib import Path

import markupsafe

assert not (Path(markupsafe.__file__).parent.parent / "MarkupSafe-3.0.2.dist-info").exists()
assert "    markupsafe: markupsafe\n" in Path(sys.argv[1]).read_text()
