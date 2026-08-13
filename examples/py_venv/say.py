#!/usr/bin/env python3

print("---")
import sys

output_base = sys.prefix.split("/execroot/")[0]
execroot = f"{output_base}/execroot"
external = f"{output_base}/external"
runfiles = sys.prefix.split(".runfiles/")[0] + ".runfiles"

def _simplify(s: str | list[str]) -> str | list[str]:
    if isinstance(s, str):
        return s \
            .replace(runfiles, "${RUNFILES}") \
            .replace(execroot, "${BAZEL_EXECROOT}") \
            .replace(external, "${BAZEL_EXTERNAL}") \
            .replace(output_base, "${BAZEL_BASE}")

    elif isinstance(s, list):
        return [_simplify(it) for it in s]

print("sys.prefix:", _simplify(sys.prefix))
print("sys.path:")
for it in _simplify(sys.path):
    print(" -", it)
import site
print("site.PREFIXES:")
for it in _simplify(site.PREFIXES):
    print(" -", it)

import cowsay

cowsay.cow('hello py_venv! (built at <BUILD_TIMESTAMP>)')
