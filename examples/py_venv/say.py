#!/usr/bin/env python3

print("---")
import sys

output_base = sys.prefix.split("/execroot/")[0]
execroot = f"{output_base}/execroot"
external = f"{output_base}/external"
runfiles = sys.prefix.split(".runfiles/")[0] + ".runfiles"

def _simplify(s: str) -> str:
    return s \
        .replace(runfiles, "${RUNFILES}") \
        .replace(execroot, "${BAZEL_EXECROOT}") \
        .replace(external, "${BAZEL_EXTERNAL}") \
        .replace(output_base, "${BAZEL_BASE}")

print("sys.prefix:", _simplify(sys.prefix))
print("sys.path:")
for it in sys.path:
    print(" -", _simplify(it))
import site
print("site.PREFIXES:")
for it in site.PREFIXES:
    print(" -", _simplify(it))

import cowsay

cowsay.cow('hello py_venv! (built at <BUILD_TIMESTAMP>)')  # type: ignore
