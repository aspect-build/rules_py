#!/usr/bin/env python3

print("---")
import _virtualenv

output_base = _virtualenv.__file__.split("/execroot/")[0]
execroot = f"{output_base}/execroot"
external = f"{output_base}/external"
runfiles = _virtualenv.__file__.split(".runfiles/")[0] + ".runfiles"

def _simlify(s):
    if isinstance(s, str):
        return s \
            .replace(runfiles, "${RUNFILES}") \
            .replace(execroot, "${BAZEL_EXECROOT}") \
            .replace(external, "${BAZEL_EXTERNAL}") \
            .replace(output_base, "${BAZEL_BASE}")

    elif isinstance(s, list):
        return [_simlify(it) for it in s]

print("virtualenv:", _simlify(_virtualenv.__file__))
import sys
print("sys.prefix:", _simlify(sys.prefix))
print("sys.path:")
for it in _simlify(sys.path):
    print(" -", it)
import site
print("site.PREFIXES:")
for it in _simlify(site.PREFIXES):
    print(" -", it)

import cowsay

cowsay.cow('hello py_binary! (built at <BUILD_TIMESTAMP>)')
