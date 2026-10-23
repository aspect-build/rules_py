#!/usr/bin/env python3

import dynver
assert "uv-dynamic-version" in dynver.__file__
assert dynver.VALUE == 42
