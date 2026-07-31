import importlib.metadata

import local_directory
import local_sdist
import local_wheel

assert local_wheel.SOURCE_KIND == "local wheel"
assert local_sdist.SOURCE_KIND == "local source archive"
assert local_directory.SOURCE_KIND == "local directory"
assert "packages/local;directory" in local_directory.__file__

for distribution in ("local-wheel", "local-sdist"):
    assert importlib.metadata.version(distribution) == "1.0.0"

print("real uv-locked local wheels, source archives, and directories: OK")
