#!/usr/bin/env python3
"""Regression test: extras requested via tool.uv.override-dependencies.

The pyproject pulls `requests` and, separately, declares
`tool.uv.override-dependencies = ["requests[socks]"]`. That extra
request lands in the lockfile under `[manifest] overrides` instead of
inside any package's `dependencies` or `requires-dist`. The optional
dependency of `requests[socks]` (pysocks, importable as `socks`) must
therefore be materialized in the venv.
"""

import requests
print(f"requests: {requests.__file__}")

# Reachable only because the manifest-level extra was threaded into
# the dependency graph.
import socks
print(f"socks: {socks.__file__}")
