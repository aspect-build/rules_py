#!/usr/bin/env bash
set -euo pipefail

# Test the alocation function from run.tmpl.sh in isolation.
# When PWD="/", joining "${PWD}/${P}" for a relative path P produces
# "//P" instead of "/P".

# This is the fixed function from run.tmpl.sh:
PWD="/"
function alocation {
  local P=$1
  if [[ "${P:0:1}" == "/" ]]; then
    echo -n "${P}"
  else
    echo -n "${PWD%/}/${P}"
  fi
}

# Absolute paths should pass through unchanged
result="$(alocation "/absolute/path")"
if [[ "$result" != "/absolute/path" ]]; then
  echo "FAIL: alocation('/absolute/path') = '$result', expected '/absolute/path'" >&2
  exit 1
fi

# Relative paths from PWD="/" must not produce double slashes
result="$(alocation "relative/path")"
if [[ "$result" == //* ]]; then
  echo "FAIL: alocation('relative/path') with PWD=/ produced double slash: '$result'" >&2
  exit 1
fi
if [[ "$result" != "/relative/path" ]]; then
  echo "FAIL: alocation('relative/path') = '$result', expected '/relative/path'" >&2
  exit 1
fi

# Also verify normal behavior with non-root PWD
PWD="/some/dir"
result="$(alocation "relative/path")"
if [[ "$result" != "/some/dir/relative/path" ]]; then
  echo "FAIL: alocation('relative/path') with PWD=/some/dir = '$result', expected '/some/dir/relative/path'" >&2
  exit 1
fi

echo "OK: alocation unit test passed"
