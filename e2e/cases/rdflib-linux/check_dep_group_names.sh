#!/usr/bin/env bash
# Regression: dep_group config_setting names must be normalized (hyphens → underscores).
# If the hub emits config_setting(name = "rdflib-linux"), then dep_group = "rdflib_linux"
# never matches and every package in the hub becomes @@platforms//:incompatible.
set -euo pipefail

BUILD_FILE="${1:?usage: check_dep_group_names.sh <dep_group/BUILD.bazel>}"

if grep -qF '"rdflib-linux"' "$BUILD_FILE"; then
    echo "FAIL: config_setting name contains hyphens: 'rdflib-linux'"
    echo "      dep_group = \"rdflib_linux\" (underscore) will never match it."
    echo "      uv_hub must normalize project names via normalize_name() before"
    echo "      emitting config_setting targets and flag_values."
    echo ""
    grep '"rdflib-linux"' "$BUILD_FILE"
    exit 1
fi

echo "PASS: all dep_group config_setting names are underscore-normalized"
