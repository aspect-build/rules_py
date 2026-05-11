"""End-to-end check that decide_marker normalizes Python arch aliases.

Pyproject declares `cowsay` under a marker using only Python-style spellings
(`platform_machine == 'arm64' or platform_machine == 'amd64'`). Bazel's
platform_machine flag emits `aarch64`/`x86_64`, so without the alias
normalization in uv/private/markers/defs.bzl the dep is selected away on
every mainstream host and this import fails at runtime.
"""

import cowsay

cowsay.cow("arch-alias-marker")
