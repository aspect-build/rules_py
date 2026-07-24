#!/usr/bin/env python3
"""Smoke test that every lock universe resolves the shared package set,
including the packages that carry an exclude_glob override."""

import cachetools
import decorator
import distlib
import inflection
import pycodestyle
import pyflakes
import sortedcontainers
import toml

assert toml.loads("k = 1")["k"] == 1
assert inflection.camelize("dedup_installs") == "DedupInstalls"
assert sortedcontainers.SortedList([3, 1, 2]) == [1, 2, 3]
