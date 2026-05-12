"""Asserts decide_marker normalizes Python arch aliases to Bazel spellings.

The accompanying BUILD wires `args` through a select() keyed on a
`decide_marker(marker = "platform_machine == 'arm64' or platform_machine == 'amd64'")`.
Both alternatives are Python-only spellings; Bazel's platform_machine flag
emits `aarch64`/`x86_64`. Without the alias normalization in decide_marker
the select() falls through to the default branch on every host.
"""

import sys

want = "matched"
got = sys.argv[1] if len(sys.argv) > 1 else "<none>"
assert got == want, (
    "decide_marker did not normalize arm64/amd64 -> aarch64/x86_64; "
    "select() picked the default branch. got=%r want=%r" % (got, want)
)
