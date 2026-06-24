"""Smoke test that cowsay built from sdist (via no-binary-package) works.

cowsay 6.0 ships both an sdist and a `-none-any.whl`. With `no-binary-package
= ["cowsay"]` the resolver must produce a `sdist_build__*` repo so the
package can be built from source. Importing and exercising cowsay verifies
the sdist build pathway end-to-end.
"""

import os
import shutil
import subprocess
from pathlib import Path

import cowsay

output = cowsay.get_output_string("cow", "sdist fallback works!")
assert "sdist fallback works!" in output
marker = "declared console script works"
wrapper = shutil.which("cowsay")
assert wrapper is not None, "cowsay wrapper is absent from PATH"
expected_wrapper = Path(os.environ["VIRTUAL_ENV"]) / "bin" / "cowsay"
assert Path(wrapper).resolve() == expected_wrapper.resolve(), (
    wrapper,
    expected_wrapper,
)
result = subprocess.run(
    [wrapper, "--text", marker],
    check=True,
    capture_output=True,
    text=True,
)
assert marker in result.stdout
print("cowsay imported from sdist: OK")
