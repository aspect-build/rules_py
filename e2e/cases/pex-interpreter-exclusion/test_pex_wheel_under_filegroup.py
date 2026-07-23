"""A wheel reached only through a `filegroup(srcs = [...])` data wrapper must
still be packaged as a PEX distribution, not as loose source.

app_wrapped_wheel depends on the distfg wheel via `data = [":wrapped_wheel"]`,
a filegroup whose `srcs` hold the wheel. The closure aspect walks the `data`
edge to the filegroup but not the filegroup's `srcs`; if the wheel's
PyWheelsInfo is missed there, its install tree is shipped as loose `--source`
content and never appears among the PEX distributions.
"""

import json
import os
import zipfile
from pathlib import Path

pex = (
    Path(os.environ["RUNFILES_DIR"])
    / "_main/pex-interpreter-exclusion/app_wrapped_wheel_pex.pex"
)
with zipfile.ZipFile(pex) as zf:
    info = json.loads(zf.read("PEX-INFO"))
    names = zf.namelist()

distributions = info.get("distributions", {})
assert any("distfg" in key for key in distributions), (
    "distfg wheel was not packaged as a PEX distribution",
    list(distributions),
)

# The distribution lives under `.deps/`, not as loose source files.
loose = [name for name in names if "distfg" in name and not name.startswith(".deps/")]
assert not loose, loose[:10]
