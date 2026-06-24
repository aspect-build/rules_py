"""Version comparison utilities for python-build-standalone version strings.

Handles PBS release and pre-release version forms:
  3.12.3, 3.13.0a6, 3.14.0b1, 3.14.0rc2

Pre-release ordering: alpha < beta < rc < release.
"""

# Pre-release phase ordering. Higher = newer.
# A release with no suffix is newer than any pre-release.
_PRE_RELEASE_ORDER = {
    "a": 0,
    "b": 1,
    "rc": 2,
}
_RELEASE_ORDER = 3  # No suffix = final release
_RELEASE_LEVELS = ["alpha", "beta", "candidate", "final"]

def is_decimal(value):
    """Whether value consists of one or more ASCII decimal digits."""
    if not value:
        return False
    for char in value.elems():
        if char not in "0123456789":
            return False
    return True

def _parse_pre_release(s):
    """Parse a version component that may contain a pre-release suffix.

    Examples:
        "3"    -> (3, _RELEASE_ORDER, 0)
        "0a6"  -> (0, 0, 6)
        "0b1"  -> (0, 1, 1)
        "0rc2" -> (0, 2, 2)

    Returns:
        A tuple (numeric_part, phase_order, phase_number) for comparison.
    """
    for tag in ["rc", "b", "a"]:
        idx = s.find(tag)
        if idx >= 0:
            num = int(s[:idx]) if idx > 0 else 0
            phase_num = int(s[idx + len(tag):]) if idx + len(tag) < len(s) else 0
            return (num, _PRE_RELEASE_ORDER[tag], phase_num)
    return (int(s), _RELEASE_ORDER, 0)

def parse_version(v):
    """Parse a PBS version for comparison and sys.version_info metadata."""
    parts = v.split(".")
    if len(parts) < 2 or len(parts) > 3:
        fail("Python version must have two or three components, got '{}'".format(v))

    components = [_parse_pre_release(part) for part in parts]
    if (
        components[0][1] != _RELEASE_ORDER or
        components[1][1] != _RELEASE_ORDER
    ):
        fail("Python prerelease suffix must follow the micro version, got '{}'".format(v))

    micro, release_order, serial = components[2] if len(components) == 3 else (0, _RELEASE_ORDER, 0)
    return struct(
        components = components,
        major = components[0][0],
        micro = micro,
        minor = components[1][0],
        releaselevel = _RELEASE_LEVELS[release_order],
        serial = serial,
    )

def is_pre_release(v):
    """Returns True if version string v is a pre-release (alpha, beta, or rc).

    Args:
        v: A version string like "3.15.0" or "3.15.0a6".

    Returns:
        True if v contains a pre-release suffix.
    """
    return parse_version(v).releaselevel != "final"

def version_gt(a, b):
    """Returns True if version string a > b.

    Handles pre-release versions (alpha, beta, rc) correctly:
      3.15.0a6 < 3.15.0b1 < 3.15.0rc1 < 3.15.0

    Args:
        a: A version string.
        b: A version string.

    Returns:
        True if a is strictly greater than b.
    """
    a_key = parse_version(a).components
    b_key = parse_version(b).components

    # Pad to equal length with (0, RELEASE, 0)
    max_len = max(len(a_key), len(b_key))
    pad = (0, _RELEASE_ORDER, 0)
    for _ in range(max_len - len(a_key)):
        a_key.append(pad)
    for _ in range(max_len - len(b_key)):
        b_key.append(pad)

    for i in range(max_len):
        if a_key[i] > b_key[i]:
            return True
        if a_key[i] < b_key[i]:
            return False
    return False
