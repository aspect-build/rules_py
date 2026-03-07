load(":versions.bzl", _find_matching_version = "find_matching_version", _parse_version = "parse_version", _version_cmp = "version_cmp", _version_satisfies = "version_satisfies")

versions = struct(
    parse = _parse_version,
    cmp = _version_cmp,
    satisfies = _version_satisfies,
    find_match = _find_matching_version,
)
