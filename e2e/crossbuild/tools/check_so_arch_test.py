#!/usr/bin/env python3
"""Fixture tests for check_so_arch: tag/.so agreement, mismatch, and skips."""
import os
import tempfile
import unittest
import zipfile

from tools import check_so_arch


def _elf(machine: int) -> bytes:
    return b"\x7fELF" + b"\x00" * 14 + machine.to_bytes(2, "little") + b"\x00" * 44


def _wheel(path: str, tag: str, libs: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("pkg-1.0.dist-info/WHEEL", "Wheel-Version: 1.0\nTag: {}\n".format(tag))
        for name, content in libs.items():
            zf.writestr(name, content)


class CheckSoArchTest(unittest.TestCase):
    def test_matching_arch_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wheel = os.path.join(tmp, "pkg-1.0-cp312-cp312-linux_aarch64.whl")
            _wheel(wheel, "cp312-cp312-linux_aarch64", {"pkg/ext.cpython-312-aarch64-linux-gnu.so": _elf(183)})
            self.assertEqual([], check_so_arch.check_wheel(wheel))

    def test_mismatched_arch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wheel = os.path.join(tmp, "pkg-1.0-cp312-cp312-linux_aarch64.whl")
            # Tagged aarch64 but the .so is x86_64 — the failure this test
            # suite exists to catch.
            _wheel(wheel, "cp312-cp312-linux_aarch64", {"pkg/ext.so": _elf(62)})
            failures = check_so_arch.check_wheel(wheel)
            self.assertEqual(1, len(failures))
            self.assertIn("e_machine=62", failures[0])

    def test_musllinux_tag_checked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wheel = os.path.join(tmp, "pkg-1.0-cp312-cp312-musllinux_1_2_x86_64.whl")
            _wheel(wheel, "cp312-cp312-musllinux_1_2_x86_64", {"pkg/ext.so": _elf(62)})
            self.assertEqual([], check_so_arch.check_wheel(wheel))

    def test_pure_wheel_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wheel = os.path.join(tmp, "pkg-1.0-py3-none-any.whl")
            _wheel(wheel, "py3-none-any", {"pkg/mod.py": b"x = 1\n"})
            self.assertEqual([], check_so_arch.check_wheel(wheel))

    def test_macos_tag_skipped(self) -> None:
        # Mach-O is not ELF; the cross matrix is Linux-only, so darwin tags
        # are out of scope for this check (documented in the module docstring).
        with tempfile.TemporaryDirectory() as tmp:
            wheel = os.path.join(tmp, "pkg-1.0-cp312-cp312-macosx_11_0_arm64.whl")
            _wheel(wheel, "cp312-cp312-macosx_11_0_arm64", {"pkg/ext.so": b"\xcf\xfa\xed\xfe"})
            self.assertEqual([], check_so_arch.check_wheel(wheel))


if __name__ == "__main__":
    unittest.main()
