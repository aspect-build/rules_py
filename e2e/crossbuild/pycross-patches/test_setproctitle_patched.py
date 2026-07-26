# Ported from rules_pycross tests/e2e/patches_and_hooks/tests/test_setproctitle.py.
# `SITE_HOOK_RAN` is dropped: rules_py has no `site_hooks` equivalent.
import unittest

import setproctitle


class TestSetproctitle(unittest.TestCase):
    def test_import(self):
        title = setproctitle.getproctitle()
        self.assertIsNotNone(title)
        self.assertTrue(setproctitle.PATCHED)
        self.assertTrue(setproctitle.POST_PATCHED)


if __name__ == "__main__":
    unittest.main()
