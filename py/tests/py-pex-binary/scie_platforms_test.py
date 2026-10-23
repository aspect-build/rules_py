"""Asserts each transitioned scie is an executable for its target platform.

A scie starts with the target's scie-jump, so its first bytes are that
platform's executable format, whichever platform built it.
"""

import os

import runfiles

r = runfiles.Create()

MAGIC = {
    "SCIE_AMD64_LINUX": b"\x7fELF",
    # Mach-O 64-bit, little-endian.
    "SCIE_ARM64_MACOS": b"\xcf\xfa\xed\xfe",
}

for env_var, magic in MAGIC.items():
    assert r is not None, "runfiles not found"
    path = r.Rlocation(os.environ[env_var], source_repo="")
    assert path is not None, "{} not found in runfiles".format(env_var)
    with open(path, "rb") as f:
        head = f.read(len(magic))
    assert head == magic, (env_var, head)

print("PASS")
