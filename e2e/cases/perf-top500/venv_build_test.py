#!/usr/bin/env python3
"""Test body for the perf-top500 venv_build target.

The body itself is near-trivial; the :all_deps dep pulls all 583
top-PyPI wheels into the venv so the test exercises the rule set's
full venv-assembly + Python-startup path. Self-measures:

  - wall time from the *test process* spawn to the start of this body
    (captures: launcher script time, any runtime venv assembly, Python
    interpreter init, site.py, .pth walk, main-module load)
  - in-body wall time for one representative dep import
  - sys.path shape

The first number is what differs most across rule sets (rules_python
~0.1 s, rules_py HEAD ~0.7 s, rules_py v1.11.5 py_venv_test ~1.2 s,
rules_py v1.11.5 py_test ~18 s — the legacy `py_test` builds the venv
at run time, which the others lift to build time).
"""

import time as _time

_T_PERF_AT_BODY = _time.perf_counter()
_T_WALL_AT_BODY = _time.time()

import os
import sys

# psutil is in the perf_top500 dep set; use it to read the process
# start time so we can derive "wall time from process spawn to body".
# Importing it is counted in that delta, which is what we want — total
# observable cost from when the test binary was exec'd until the test
# script can do work.
import psutil

_proc = psutil.Process()
_spawn_to_body = _T_WALL_AT_BODY - _proc.create_time()

# Time one representative import to give a per-dep cost number. requests
# is small, pure-Python, ubiquitous; its import walks the namespace
# package machinery once and then sits.
_t = _time.perf_counter()
import requests  # noqa: F401
_import_requests = _time.perf_counter() - _t

# sys.path shape — distinct roots vs total entries reveals layout
# (rules_py uses ~one consolidated venv root, rules_python sprays one
# site-packages per wheel into PYTHONPATH).
roots = set()
for p in sys.path:
    if "site-packages" in p:
        roots.add(p.split("site-packages", 1)[0])

print(f"perf_top500 venv built")
print(f"  spawn_to_body_wall      {_spawn_to_body * 1000:.1f} ms")
print(f"  import_requests         {_import_requests * 1000:.1f} ms")
print(f"  sys.path entries        {len(sys.path)}")
print(f"  distinct sp roots       {len(roots)}")

# Distinguish entries that resolve to the same realpath
_realpath_groups: dict[str, list[str]] = {}
for p in sys.path:
    if p:
        rp = os.path.realpath(p)
        _realpath_groups.setdefault(rp, []).append(p)
_dupe_realpaths = {rp: vs for rp, vs in _realpath_groups.items() if len(vs) > 1}
print(f"  distinct realpaths      {len(_realpath_groups)}")
print(f"  dupe realpaths          {len(_dupe_realpaths)}")
if _dupe_realpaths:
    for rp, vs in list(_dupe_realpaths.items())[:3]:
        print(f"    {rp}")
        for v in vs:
            print(f"      <- {v}")
