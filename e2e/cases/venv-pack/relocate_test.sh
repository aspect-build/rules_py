#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$#" -ge 1 ] || fail "usage: $0 <layer.tar.gz>..."

dest="${TEST_TMPDIR}/opt/snowflake"
mkdir -p "$dest"
for layer in "$@"; do
    archive="${TEST_SRCDIR}/${TEST_WORKSPACE}/${layer}"
    [ -f "$archive" ] || fail "layer not found at $archive"
    tar -xzf "$archive" -C "$dest"
done

echo "== no symlink may point outside the extracted tree =="
absolute_links="$(find "$dest" -type l -lname '/*')"
[ -z "$absolute_links" ] || fail "absolute symlink targets:"$'\n'"$absolute_links"

echo "== no symlink may dangle =="
dangling="$(find "$dest" -type l ! -exec test -e {} \; -print)"
[ -z "$dangling" ] || fail "dangling symlinks after relocation:"$'\n'"$dangling"

venv="${dest}/app.runfiles/_main/venv-pack/.env"
[ -f "$venv/pyvenv.cfg" ] || fail "missing $venv/pyvenv.cfg"
[ -L "$venv/bin/python" ] || fail "$venv/bin/python must stay a symlink"
[ -f "$venv/bin/activate" ] || fail "missing $venv/bin/activate"

echo "== exec bin/python directly =="
"$venv/bin/python" -c 'import cowsay' || fail "bin/python cannot import cowsay"

echo "== source bin/activate under a scrubbed environment =="
cd /
env -i PATH=/usr/bin:/bin HOME="$TEST_TMPDIR" VENV="$venv" DEST="$dest" bash -o errexit -o nounset -o pipefail <<'ACTIVATED'
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

. "$VENV/bin/activate"

[ "${VIRTUAL_ENV:-}" = "$VENV" ] || fail "VIRTUAL_ENV=${VIRTUAL_ENV:-<unset>}, want $VENV"

resolved="$(command -v python)"
[ "$resolved" = "$VENV/bin/python" ] || fail "python on PATH is $resolved, want $VENV/bin/python"

python3.11 --version >/dev/null || fail "python3.11 does not run"

python - "$VENV" "$DEST" <<'PY'
import os
import sys

venv, dest = sys.argv[1], sys.argv[2]

assert sys.prefix == venv, (sys.prefix, venv)
assert sys.base_prefix != sys.prefix, "not running inside the venv"
assert os.path.realpath(sys.executable).startswith(dest), os.path.realpath(sys.executable)
assert os.path.realpath(sys.base_prefix).startswith(dest), sys.base_prefix

import cowsay

assert cowsay.__file__ is not None
assert os.path.realpath(cowsay.__file__).startswith(dest), os.path.realpath(cowsay.__file__)

for entry in sys.path:
    if entry and not entry.endswith(".zip"):
        assert os.path.exists(entry), entry
        assert os.path.realpath(entry).startswith(dest), entry

import encodings, ssl, sqlite3, zlib

print("venv ok:", sys.version.split()[0], sys.prefix)
PY

deactivate
[ -z "${VIRTUAL_ENV:-}" ] || fail "deactivate left VIRTUAL_ENV set"
[ "$(command -v python || true)" != "$VENV/bin/python" ] || fail "deactivate left venv bin on PATH"
ACTIVATED

echo "PASS: relocated venv activates and runs from $dest"
