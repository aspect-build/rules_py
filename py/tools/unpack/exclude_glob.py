"""Match site-packages-relative wheel exclusion globs."""

import argparse


# Keep the parser and matcher in sync with uv/private/whl_install/repository.bzl;
# exclude_glob_test_vectors.bzl exercises their shared valid inputs.
def parse(value):
    parts = value.split("/")
    if (
        not value
        or "\\" in value
        or any(
            not part
            or part in (".", "..")
            or any(character in part for character in ":?[]")
            or ("**" in part and part != "**")
            for part in parts
        )
    ):
        raise argparse.ArgumentTypeError("invalid wheel exclude glob: {}".format(value))
    return tuple(parts)


def _matches_chunk(value, pattern):
    parts = pattern.split("*")
    if len(parts) == 1:
        return value == pattern
    if not value.startswith(parts[0]) or not value.endswith(parts[-1]):
        return False
    if len(parts[0]) + len(parts[-1]) > len(value):
        return False
    value = value[len(parts[0]):]
    if parts[-1]:
        value = value[:-len(parts[-1])]
    for part in parts[1:-1]:
        index = value.find(part)
        if index < 0:
            return False
        value = value[index + len(part):]
    return True


def _matches(path, pattern):
    pending = [(0, 0)]
    visited = set()
    while pending:
        path_index, pattern_index = pending.pop()
        if (path_index, pattern_index) in visited:
            continue
        visited.add((path_index, pattern_index))
        if pattern_index == len(pattern):
            if path_index == len(path):
                return True
            continue
        if pattern[pattern_index] == "**":
            pending.append((path_index, pattern_index + 1))
            if path_index < len(path):
                pending.append((path_index + 1, pattern_index))
        elif path_index < len(path) and _matches_chunk(
            path[path_index], pattern[pattern_index]
        ):
            pending.append((path_index + 1, pattern_index + 1))
    return False


def excluded(path, patterns):
    # Repository topology later drops escaping RECORD paths; the disk sweep only
    # visits site-packages, but keep this guard for direct callers.
    return bool(path) and path[0] not in ("", ".", "..") and any(
        _matches(path, pattern + ("**",)) for pattern in patterns
    )
