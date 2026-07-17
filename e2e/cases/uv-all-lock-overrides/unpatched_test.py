"""Checks that a lock with a different package version was left unchanged."""

import boltons

assert not hasattr(boltons, "ALL_LOCKS_PATCHED")
