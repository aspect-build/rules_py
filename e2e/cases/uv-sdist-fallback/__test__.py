"""Smoke test that cowsay built from sdist (via no-binary-package) works.

cowsay 6.0 ships both an sdist and a `-none-any.whl`. With `no-binary-package
= ["cowsay"]` the resolver must produce a `sdist_build__*` repo so the
package can be built from source. Importing and exercising cowsay verifies
the sdist build pathway end-to-end.
"""

import subprocess
import sys
from pathlib import Path

import cowsay

output = cowsay.get_output_string("cow", "sdist fallback works!")
assert "sdist fallback works!" in output

cowsay_script = Path(sys.prefix) / "bin" / "cowsay"
result = subprocess.run(
    [cowsay_script, "-t", "source metadata works!"],
    capture_output=True,
    text=True,
)
assert result.returncode == 0, result.stderr
assert "source metadata works!" in result.stdout
print("cowsay imported from sdist: OK")
