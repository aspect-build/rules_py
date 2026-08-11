"""Smoke test for setproctitle built from its sdist.

Ported from rules_pycross tests/e2e/build_setuptools/tests/test_setproctitle.py.
require_extension.patch makes the C extension mandatory, so a passing import
here means the native build ran — the upstream pure-Python fallback cannot
have papered over a compile failure.
"""

import unittest

import setproctitle


class TestSetproctitle(unittest.TestCase):
    def test_import(self) -> None:
        title = setproctitle.getproctitle()
        self.assertIsNotNone(title)


if __name__ == "__main__":
    unittest.main()
