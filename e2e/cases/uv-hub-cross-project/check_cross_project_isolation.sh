#!/usr/bin/env bash
set -euo pipefail

BUILD="${1:?}"

if grep -qF "other_project" "$BUILD"; then
    echo "FAIL: rdflib alias contains other_project arm — cross-project contamination"
    grep "other_project" "$BUILD"
    exit 1
fi

if ! grep -qF "rdflib_project" "$BUILD"; then
    echo "FAIL: rdflib alias missing rdflib_project arm"
    cat "$BUILD"
    exit 1
fi

echo "PASS: rdflib isolated to rdflib_project"
