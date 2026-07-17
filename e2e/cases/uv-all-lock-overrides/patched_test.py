"""Checks that the matching lock received the all-lock post-install patch."""

import boltons

assert boltons.ALL_LOCKS_PATCHED is True
