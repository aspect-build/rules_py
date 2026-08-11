"""Assert both patch phases reached the installed setproctitle.

Ported from rules_pycross tests/e2e/patches_and_hooks/tests/test_setproctitle.py.
`PATCHED` comes from the pre-build patch, `POST_PATCHED` from the post-install
patch. The upstream `SITE_HOOK_RAN` assertion is dropped: rules_py has no
`site_hooks` equivalent.
"""

import unittest

import setproctitle


class TestSetproctitle(unittest.TestCase):
    def test_import(self) -> None:
        title = setproctitle.getproctitle()
        self.assertIsNotNone(title)
        self.assertTrue(setproctitle.PATCHED)
        self.assertTrue(setproctitle.POST_PATCHED)


if __name__ == "__main__":
    unittest.main()
