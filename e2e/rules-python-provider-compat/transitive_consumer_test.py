"""Asserts the whole rules_py closure, not just the direct dep, is visible."""

import middle

assert middle.VALUE == "middle+leaf", middle.VALUE
