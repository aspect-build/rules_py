#!/usr/bin/env bash
# Regression: an external-repo source has runfiles short_path
# ../test_driver_extrepo/... . The driver must strip the leading ../ when
# deriving the module name, so the JUnit classname is a clean dotted path
# (test_driver_extrepo.ext_unittest_test.…) rather than one with leading dots
# (...test_driver_extrepo.…). Drives :external_src_test with a synthesized
# XML_OUTPUT_FILE and inspects the emitted classname.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/external_src_test"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

XML="$(mktemp -d)/test.xml"

# The external source has one passing test, so the launcher exits 0.
XML_OUTPUT_FILE="$XML" "$LAUNCHER"

[[ -s "$XML" ]] || {
  echo "JUnit XML file empty or missing: $XML" >&2
  exit 1
}

# The stripped module path reaches the classname (repo name is bzlmod-mangled).
grep -q 'test_driver_extrepo.ext_unittest_test.ExternalRepoTest' "$XML" || {
  echo "Expected the external module path in the classname." >&2
  cat "$XML" >&2
  exit 1
}

# The biting check: without the ../ strip the classname begins with leading dots.
if grep -q 'classname="\.' "$XML"; then
  echo "classname begins with a dot — the ../ prefix was not stripped." >&2
  cat "$XML" >&2
  exit 1
fi

echo "OK: external-repo source yields a clean JUnit classname."
