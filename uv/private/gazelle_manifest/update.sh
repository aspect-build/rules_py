#!/usr/bin/env sh

# Use cat rather than cp to avoid retaining r/o permissions
cat "$1" > "$BUILD_WORKSPACE_DIRECTORY/$2"
