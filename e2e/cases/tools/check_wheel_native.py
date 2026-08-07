"""Assert cross-built wheels really contain extensions for the tagged platform.

Usage: check_wheel_native.py <collected-wheel-dir>

For every Linux-tagged wheel in the directory, every extension module inside it
must be an ELF object whose `e_machine` matches the wheel's architecture tag,
and whose filename ABI tag names the same architecture. A cross build that
fell back to the exec platform's compiler or sysconfig produces a correctly
named wheel holding host-architecture objects — which the wheel-tag check
alone cannot see.

rules_pycross's cross coverage stops at "the wheel builds for both platforms"
(tests/e2e/shared/collect_wheels.bzl feeding a build target); this is the
assertion that makes that matrix meaningful.
"""

import os
import struct
import sys
import zipfile

# ELF e_machine values, from elf.h.
_EM_X86_64 = 0x3E
_EM_AARCH64 = 0xB7

_ARCH_TAGS = {
    "x86_64": _EM_X86_64,
    "aarch64": _EM_AARCH64,
}


def _wheel_arch(name: str) -> str:
    for arch in _ARCH_TAGS:
        if arch in name:
            return arch
    raise AssertionError("cannot determine architecture from wheel name {}".format(name))


def _elf_machine(data: bytes) -> int:
    assert data[:4] == b"\x7fELF", "not an ELF object"
    little_endian = data[5] == 1
    return struct.unpack_from("<H" if little_endian else ">H", data, 18)[0]


def _check(wheel_path: str) -> int:
    name = os.path.basename(wheel_path)
    arch = _wheel_arch(name)
    expected_machine = _ARCH_TAGS[arch]
    checked = 0

    with zipfile.ZipFile(wheel_path) as zf:
        for entry in zf.namelist():
            if not entry.endswith(".so"):
                continue
            machine = _elf_machine(zf.read(entry))
            if machine != expected_machine:
                raise AssertionError(
                    "{}: {} is ELF machine {:#x}, expected {:#x} for '{}'".format(
                        name, entry, machine, expected_machine, arch
                    )
                )
            base = os.path.basename(entry)
            if "." in base[:-3] and arch not in base:
                raise AssertionError(
                    "{}: extension filename '{}' does not name architecture '{}'".format(
                        name, base, arch
                    )
                )
            print("  {} -> {} (ELF {:#x})".format(name, base, machine))
            checked += 1

    return checked


def main() -> None:
    wheel_dir = sys.argv[1]
    wheels = sorted(
        f
        for f in os.listdir(wheel_dir)
        if f.endswith(".whl") and "linux" in f and not f.endswith("-none-any.whl")
    )
    assert wheels, "no Linux-tagged native wheels collected under {}".format(wheel_dir)

    total = 0
    for wheel in wheels:
        total += _check(os.path.join(wheel_dir, wheel))

    assert total, "collected native wheels contain no extension modules: {}".format(wheels)


if __name__ == "__main__":
    main()
