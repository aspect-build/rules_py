import sys
from pathlib import Path

manifest = Path(sys.argv[1]).read_text().splitlines()

# No wheel for this platform, so indexed from a Windows wheel.
assert "    pythoncom: pywin32" in manifest, manifest
# Has an sdist, but indexed from a Windows wheel rather than a source build.
assert "    winpty: pywinpty" in manifest, manifest
