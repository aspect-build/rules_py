#!/usr/bin/env python3
# Regression: shared group must resolve even though its lock entries carry
# `extra == 'group-24-...'` markers that uv uses for conflict routing.
# Any packaging version >= 20.0 is valid here — the point is that Bazel
# analysis succeeds and the dependency resolves at all.

from importlib import metadata
version = metadata.version("packaging")
assert version in ("21.3", "24.0"), "unexpected packaging version: {}".format(version)
