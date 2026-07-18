"""Smoke test that cowsay built from sdist (via no-binary-package) works.

cowsay 6.0 ships both an sdist and a `-none-any.whl`. With `no-binary-package
= ["cowsay"]` the resolver must produce a `sdist_build__*` repo so the
package can be built from source. Importing and exercising cowsay verifies
the sdist build pathway end-to-end.
"""

import importlib.metadata
import os
import shutil
import subprocess
import sys
from pathlib import Path

import cowsay

package = Path(cowsay.__file__).parent
assert not (package / "tests").exists()
assert not list(package.rglob("test_*.pyc"))
distribution = importlib.metadata.distribution("cowsay")
assert not (package.parent / "cowsay-6.0.dist-info" / "licenses").exists()
assert distribution.files is not None
recorded = {str(path) for path in distribution.files}
assert "cowsay/main.py" in recorded
assert "cowsay: cowsay" in Path(sys.argv[1]).read_text()
assert not any(path.endswith("LICENSE.txt") or "/tests/" in path or path.endswith(".pyc") for path in recorded)
for path in distribution.files:
    installed = package.parent / path
    assert installed.is_file(), path
    if str(path).endswith(".dist-info/RECORD"):
        assert path.hash is None and path.size is None, path
        continue
    assert path.hash is not None and path.size == installed.stat().st_size, path

output = cowsay.get_output_string("cow", "sdist fallback works!")
assert "sdist fallback works!" in output
marker = "detected console script works"
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
