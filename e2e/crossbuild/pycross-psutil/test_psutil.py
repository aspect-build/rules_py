"""Smoke test for psutil built from its sdist.

Ported from rules_py/e2e/crossbuild/psutil/psutil_main.py. cpu_count() and
virtual_memory().total read real /proc/cpuinfo and /proc/meminfo via psutil's
compiled Linux backend (_psutil_linux.so) — both must be positive on any real
(or QEMU-emulated) Linux system.
"""

import unittest

import psutil


class TestPsutil(unittest.TestCase):
    def test_cpu_count(self) -> None:
        cpu_count = psutil.cpu_count()
        self.assertIsNotNone(cpu_count)
        self.assertGreaterEqual(cpu_count, 1)

    def test_virtual_memory(self) -> None:
        mem_total = psutil.virtual_memory().total
        self.assertGreater(mem_total, 0)


if __name__ == "__main__":
    unittest.main()
