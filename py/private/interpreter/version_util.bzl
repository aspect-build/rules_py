"""Version comparison utilities for python-build-standalone version strings.

Handles PEP 440-style versions including pre-release suffixes:
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

def version_key(v):
    """Convert a version string to a comparable tuple.

    Args:
        v: A version string like "3.12.3" or "3.15.0a6".

    Returns:
        A tuple that can be compared with < and > operators.
    """
    parts = v.split(".")
    result = []
    for p in parts:
        result.append(_parse_pre_release(p))
    return result

def is_pre_release(v):
    """Returns True if version string v is a pre-release (alpha, beta, or rc).

    Args:
        v: A version string like "3.15.0" or "3.15.0a6".

    Returns:
        True if v contains a pre-release suffix.
    """
    for tag in ["rc", "b", "a"]:
        if tag in v:
            return True
    return False

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
    a_key = version_key(a)
    b_key = version_key(b)

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
