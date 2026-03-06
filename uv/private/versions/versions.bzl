"""PEP 440 version parsing and specifier matching for Starlark.

Provides functions to parse version strings and evaluate version specifiers
(e.g., ">=1.0", "~=2.1", "!=3.0") against candidate versions.
"""

def parse_version(v):
    """Parses a PEP 440 version string into a comparable list of integers.

    Pre-release/post-release suffixes are stripped; we only need to match
    against lockfile-resolved versions which are exact.

    Args:
        v: A version string like "1.2.3", "21.3", "2.0.0rc1".

    Returns:
        A list of integers representing the numeric version segments.
    """
    v = v.strip()

    # Strip epoch (e.g., "1!2.0" -> "2.0")
    bang = v.find("!")
    if bang != -1:
        v = v[bang + 1:]

    # Find where the numeric portion ends
    end = len(v)
    for i in range(len(v)):
        c = v[i]
        if c != "." and not c.isdigit():
            end = i
            break

    numeric = v[:end]
    if not numeric:
        return [0]

    parts = numeric.split(".")
    result = []
    for p in parts:
        if p == "":
            result.append(0)
        else:
            result.append(int(p))
    return result

def _pad(a, b):
    """Pads two version lists to the same length with trailing zeros."""
    la = len(a)
    lb = len(b)
    if la < lb:
        a = a + [0] * (lb - la)
    elif lb < la:
        b = b + [0] * (la - lb)
    return a, b

def version_cmp(a, b):
    """Compares two parsed version lists.

    Args:
        a: First parsed version (list of ints).
        b: Second parsed version (list of ints).

    Returns:
        -1 if a < b, 0 if a == b, 1 if a > b.
    """
    a, b = _pad(a, b)
    for i in range(len(a)):
        if a[i] < b[i]:
            return -1
        if a[i] > b[i]:
            return 1
    return 0

def _check_wildcard(version, op, prefix_str):
    """Handles wildcard version matching (e.g., ==1.0.*).

    Args:
        version: Parsed version (list of ints).
        op: The operator ("==" or "!=").
        prefix_str: The version prefix without the trailing ".*".

    Returns:
        True if the version matches.
    """
    prefix = parse_version(prefix_str)
    for i in range(len(prefix)):
        v = version[i] if i < len(version) else 0
        if op == "==" and v != prefix[i]:
            return False
        if op == "!=" and v != prefix[i]:
            return True

    return op == "=="

def _check_single(version, spec):
    """Evaluates a single version specifier against a parsed version.

    Args:
        version: Parsed version (list of ints).
        spec: A single specifier string like ">=1.0" or "~=2.1".

    Returns:
        True if the version matches.
    """

    op = ""
    target_str = ""

    if spec.startswith("~="):
        op = "~="
        target_str = spec[2:].strip()
    elif spec.startswith("==="):
        op = "==="
        target_str = spec[3:].strip()
    elif spec.startswith("=="):
        op = "=="
        target_str = spec[2:].strip()
    elif spec.startswith("!="):
        op = "!="
        target_str = spec[2:].strip()
    elif spec.startswith(">="):
        op = ">="
        target_str = spec[2:].strip()
    elif spec.startswith("<="):
        op = "<="
        target_str = spec[2:].strip()
    elif spec.startswith(">"):
        op = ">"
        target_str = spec[1:].strip()
    elif spec.startswith("<"):
        op = "<"
        target_str = spec[1:].strip()
    else:
        op = "=="
        target_str = spec.strip()

    # Handle wildcard matches (e.g., "==1.0.*")
    if target_str.endswith(".*"):
        return _check_wildcard(version, op, target_str[:-2])

    target = parse_version(target_str)
    cmp = version_cmp(version, target)

    if op == "==":
        return cmp == 0
    elif op == "!=":
        return cmp != 0
    elif op == ">=":
        return cmp >= 0
    elif op == "<=":
        return cmp <= 0
    elif op == ">":
        return cmp > 0
    elif op == "<":
        return cmp < 0
    elif op == "~=":
        # ~=X.Y   is  >=X.Y, <(X+1).0
        # ~=X.Y.Z is  >=X.Y.Z, <X.(Y+1).0
        if cmp < 0:
            return False
        upper = list(target)
        if len(upper) < 2:
            return True
        upper = upper[:-1]
        upper[-1] = upper[-1] + 1
        return version_cmp(version, upper) < 0
    elif op == "===":
        return version == parse_version(target_str)
    else:
        fail("Unsupported version operator: {}".format(op))

def version_satisfies(version_str, specifier):
    """Checks if a version string satisfies a PEP 440 version specifier.

    Supports: ==, !=, >=, <=, >, <, ~=, ===
    Supports compound specifiers separated by commas (e.g., ">=1.0,<2.0").

    Args:
        version_str: The version to test (e.g., "24.0").
        specifier: The specifier string (e.g., ">=21.0,<25.0").

    Returns:
        True if the version satisfies all constraints, False otherwise.
    """
    version = parse_version(version_str)

    parts = specifier.split(",")
    for part in parts:
        part = part.strip()
        if not part:
            continue
        if not _check_single(version, part):
            return False
    return True

def find_matching_version(specifier, candidate_versions):
    """Finds the version from candidates that satisfies a specifier.

    When a dependency group lists a requirement like "numpy>=2.0", and the
    lockfile contains multiple versions of numpy (due to conflicts), this
    function determines which lockfile version the specifier refers to.

    Args:
        specifier: The version specifier string (e.g., ">=2.0", "==24.0").
        candidate_versions: A dict of {version_string: value} where the
            values are the dependency tuples from the lockfile.

    Returns:
        The matching value, or None if no candidate matches.
    """
    for version_str, value in candidate_versions.items():
        if version_satisfies(version_str, specifier):
            return value
    return None
