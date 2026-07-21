"""Smoke test that cowsay and tqdm built from sdist work.

cowsay 6.0 and tqdm 4.52.0 both ship an sdist and a `-none-any.whl`. With
`no-binary-package = ["cowsay", "tqdm"]` the resolver must produce
`sdist_build__*` repos so both packages can be built from source.
"""

import os
import shutil
import subprocess
from pathlib import Path

import cowsay
import socks
import tqdm

output = cowsay.get_output_string("cow", "sdist fallback works!")
assert "sdist fallback works!" in output
assert list(tqdm.tqdm(range(2), disable=True)) == [0, 1]
assert hasattr(socks, "socksocket"), "urllib3[socks] build extra was not activated"
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
print("cowsay and tqdm imported from sdist: OK")
