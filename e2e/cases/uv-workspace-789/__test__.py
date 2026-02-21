#!/usr/bin/env python3

import pi
assert "uv-workspace-789" in pi.__file__

import foo
assert "uv-workspace-789" in foo.__file__

import requests
assert ".runfiles" in requests.__file__
