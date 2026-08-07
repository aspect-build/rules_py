"""Compares our cross-compiled zstandard backend_c against PyPI's official wheel.

Loads both .so files (ours via the normal import, the official one from an
arbitrary path via importlib) into the same process and checks they agree —
not just that both look like the right architecture, but that they actually
compute identical results.
"""

import importlib.util
import platform
import sys
import types

import zstandard.backend_c as ours
from bazel_tools.tools.python.runfiles import runfiles

_DATA = b"The quick brown fox jumps over the lazy dog. " * 500

_OFFICIAL_SO = {
    "x86_64": "official_zstandard_amd64_linux/zstandard/backend_c.cpython-312-x86_64-linux-gnu.so",
    "aarch64": "official_zstandard_arm64_linux/zstandard/backend_c.cpython-312-aarch64-linux-gnu.so",
}


def _load(path: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("backend_c", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> None:
    machine = platform.machine()
    rlocation = _OFFICIAL_SO.get(machine)
    if not rlocation:
        sys.exit("unsupported machine: {}".format(machine))

    official_path = runfiles.Create().Rlocation(rlocation)
    official = _load(official_path)

    ours_compressed = ours.ZstdCompressor(level=3).compress(_DATA)
    official_compressed = official.ZstdCompressor(level=3).compress(_DATA)

    assert ours_compressed == official_compressed, "compressed output differs between our build and the official wheel"
    assert official.ZstdDecompressor().decompress(ours_compressed) == _DATA
    assert ours.ZstdDecompressor().decompress(official_compressed) == _DATA

    print("PASS: identical compressed output, cross-decompression OK")


if __name__ == "__main__":
    main()
