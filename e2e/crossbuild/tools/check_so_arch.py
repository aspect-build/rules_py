"""Assert every native .so inside a collected wheel matches its platform tag.

Usage: check_so_arch.py <dir>

For each wheel in the directory, reads its dist-info WHEEL `Tag:` entries and
verifies that every bundled native library (.so) is an ELF whose e_machine
matches the architecture the tag claims. A cross build that produced a wheel
tagged linux_aarch64 whose .so is actually x86_64 — wrong wrapper, leaked
host sysroot, misdetected toolchain — fails here even if the tags test and
the build both passed.

Wheels with no native libraries (pure Python) are skipped, as are non-Linux
tags (macOS uses Mach-O, not ELF; the cross matrix is Linux-only).
"""

import os
import sys
import zipfile

ELF_MAGIC = b"\x7fELF"

# ELF e_machine (2 bytes, little-endian, offset 18) by tag architecture.
_E_MACHINE = {
    "x86_64": 62,    # EM_X86_64
    "aarch64": 183,  # EM_AARCH64
}


def _wheel_tags(zf: zipfile.ZipFile) -> list[str]:
    for name in zf.namelist():
        root, sep, rest = name.partition("/")
        if sep and root.endswith(".dist-info") and rest == "WHEEL":
            lines = zf.read(name).decode("utf-8").splitlines()
            return [
                line.split(":", 1)[1].strip()
                for line in lines
                if line.startswith("Tag:")
            ]
    return []


def _native_libs(zf: zipfile.ZipFile) -> list[str]:
    result = []
    for name in zf.namelist():
        basename = name.rsplit("/", 1)[-1]
        if basename.endswith(".so") or ".so." in basename:
            result.append(name)
    return result


def _tag_arch(tag: str) -> str | None:
    """The architecture a platform tag claims, or None for non-Linux tags.

    linux_x86_64 -> "x86_64", musllinux_1_2_aarch64 -> "aarch64".
    """
    platform = tag.rsplit("-", 1)[-1]
    if not platform.startswith(("linux_", "musllinux_")):
        return None
    # The architecture is the trailing component(s); x86_64 itself contains
    # an underscore, so match known arches by suffix rather than splitting.
    for arch in _E_MACHINE:
        if platform.endswith("_" + arch) or platform == arch:
            return arch
    return None


def check_wheel(path: str) -> list[str]:
    """Failures for one wheel: one string per (tag, .so) mismatch."""
    failures = []
    with zipfile.ZipFile(path) as zf:
        arches = {
            arch
            for arch in (_tag_arch(tag) for tag in _wheel_tags(zf))
            if arch is not None
        }
        if not arches:
            return []
        libs = _native_libs(zf)
        for lib in libs:
            with zf.open(lib) as f:
                header = f.read(20)
            if header[:4] != ELF_MAGIC:
                failures.append("{}: {} is not ELF".format(path, lib))
                continue
            machine = int.from_bytes(header[18:20], "little")
            if any(machine != _E_MACHINE.get(arch) for arch in arches):
                failures.append(
                    "{}: {} ELF e_machine={} but the wheel is tagged for {}".format(
                        path, lib, machine, sorted(arches),
                    )
                )
    return failures


def main() -> None:
    wheel_dir = sys.argv[1]
    names = sorted(f for f in os.listdir(wheel_dir) if f.endswith(".whl"))
    assert names, "no wheels collected under {}".format(wheel_dir)

    checked = 0
    failures = []
    for name in names:
        wheel = os.path.join(wheel_dir, name)
        with zipfile.ZipFile(wheel) as zf:
            libs = _native_libs(zf)
        checked += len(libs)
        failures.extend(check_wheel(wheel))

    if failures:
        for failure in failures:
            print("FAIL:", failure)
        raise SystemExit(1)
    if checked == 0:
        print("PASS: no native libraries to check (pure wheels)")
    else:
        print("PASS: {} native librar{} match their wheel tags".format(checked, "y" if checked == 1 else "ies"))


if __name__ == "__main__":
    main()
