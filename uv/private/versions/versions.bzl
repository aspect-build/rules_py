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

def _number(value):
    end = 0
    for char in value.elems():
        if not char.isdigit():
            break
        end += 1
    return (int(value[:end]) if end else 0, value[end:], end > 0)

def _suffix(value, spellings):
    value = value.lstrip("._-")
    for spelling in spellings:
        if value.startswith(spelling):
            number, tail, _ = _number(value[len(spelling):].lstrip("._-"))
            return number, tail, spelling
    return 0, value, ""

def _trim(release):
    release = list(release)
    for _ in range(len(release)):
        if len(release) == 1 or release[-1] != 0:
            break
        release.pop()
    return tuple(release)

def _pep440(version):
    value, has_local, local = version.strip().lower().partition("+")
    if value.startswith("v"):
        value = value[1:]

    epoch, bang, value_with_epoch = value.partition("!")
    if bang:
        if not epoch.isdigit():
            return None
        epoch = int(epoch)
        value = value_with_epoch
    else:
        epoch = 0

    end = 0
    for char in value.elems():
        if not char.isdigit() and char != ".":
            break
        end += 1
    release = value[:end].rstrip(".").split(".")
    if not release or not all([part.isdigit() for part in release]):
        return None
    release = [int(part) for part in release]
    suffix = value[end:]

    # PEP 440 permits case-insensitive pre/post/dev spellings, optional
    # separators, implicit zeroes, and '.', '-', or '_' in local labels.
    # https://packaging.python.org/en/latest/specifications/version-specifiers/#normalization
    pre_number, suffix, pre = _suffix(suffix, ["preview", "alpha", "beta", "pre", "rc", "c", "a", "b"])
    if pre:
        pre = {"alpha": 0, "a": 0, "beta": 1, "b": 1, "preview": 2, "pre": 2, "rc": 2, "c": 2}[pre]
    else:
        pre = 3

    implicit_post = suffix.startswith("-") and suffix[1:].isdigit()
    if implicit_post:
        post = int(suffix[1:])
        suffix = ""
    else:
        post, suffix, post_spelling = _suffix(suffix, ["post", "rev", "r"])
        if not post_spelling:
            post = -1

    dev, suffix, dev_spelling = _suffix(suffix, ["dev"])
    if suffix.lstrip("._-"):
        return None
    if not dev_spelling:
        dev = -1

    local_key = []
    if has_local:
        local = local.replace("-", ".").replace("_", ".")
        for part in local.split("."):
            if not part or not all([char.isdigit() or char in "abcdefghijklmnopqrstuvwxyz" for char in part.elems()]):
                return None
            local_key.append((1, int(part), "") if part.isdigit() else (0, 0, part))

    # The public key follows PEP 440's epoch/release/pre/post/dev ordering;
    # development-only releases sort before alpha and numeric local segments
    # sort after lexicographic ones.
    # https://packaging.python.org/en/latest/specifications/version-specifiers/#summary-of-permitted-suffixes-and-relative-ordering
    if pre == 3 and post == -1 and dev != -1:
        pre = -1
    public = (epoch, _trim(release), pre, pre_number, post, (0, dev) if dev != -1 else (1, 0))
    return struct(
        key = public + (tuple(local_key),),
        local = bool(has_local),
        public = public,
        release = release,
    )

def _legacy(version):
    value, _, build = version.strip().lower().partition("+")
    release, _, pre = value.partition("-")
    pre_key = tuple([
        (0, int(part), "") if part.isdigit() else (1, 0, part)
        for part in pre.split(".")
    ]) if pre else ()
    return (_trim(parse_version(release)), not bool(pre), pre_key, build)

def _check_wildcard(version_str, version, op, prefix_str):
    prefix = _pep440(prefix_str)
    length = len(prefix.release if prefix else parse_version(prefix_str))
    release, prefix_release = _pad(version.release if version else parse_version(version_str), prefix.release if prefix else parse_version(prefix_str))
    matches = release[:length] == prefix_release[:length]
    if version != None and prefix != None:
        matches = matches and version.public[0] == prefix.public[0]
    return matches if op == "==" else not matches

def _check_single(version_str, spec):
    op = "=="
    target_str = spec.strip()
    for candidate in ["===", "~=", "==", "!=", ">=", "<=", ">", "<"]:
        if target_str.startswith(candidate):
            op = candidate
            target_str = target_str[len(candidate):].strip()
            break

    # Arbitrary equality intentionally bypasses normalization.
    # https://packaging.python.org/en/latest/specifications/version-specifiers/#arbitrary-equality
    if op == "===":
        return version_str.lower() == target_str.lower()

    version = _pep440(version_str)
    if target_str.endswith(".*"):
        if op not in ["==", "!="]:
            return False
        return _check_wildcard(version_str, version, op, target_str[:-2])
    target = _pep440(target_str)

    if version == None or target == None:
        left = _legacy(version_str)
        right = _legacy(target_str)
    else:
        if target.local and op in ["<", "<=", ">", ">=", "~="]:
            return version_str == target_str if op in ["<=", ">="] else False
        left = version.key if target.local else version.public
        right = target.key if target.local else target.public

    if op == "==":
        return left == right
    if op == "!=":
        return left != right
    if op == ">=":
        return left >= right
    if op == "<=":
        return left <= right
    if op == ">":
        # Exclusive lower bounds reject only a post-release of that exact
        # bound, not every post-release sharing its numeric release.
        # https://packaging.python.org/en/latest/specifications/version-specifiers/#exclusive-ordered-comparison
        if version != None and target != None and version.public[4] != -1 and version.public[:4] + (-1, (1, 0)) == target.public:
            return False
        return left > right
    if op == "<":
        if version != None and target != None and target.public[2] == 3 and target.public[4] == -1:
            # Exclusive final-release bounds use the corresponding dev0 key,
            # which excludes prereleases of the bound but admits post bounds.
            # https://packaging.python.org/en/latest/specifications/version-specifiers/#exclusive-ordered-comparison
            right = target.public[:2] + (-1, 0, -1, (0, 0))
        return left < right
    if op == "~=":
        if left < right:
            return False
        release = list(target.release if target else parse_version(target_str))
        if len(release) == 1:
            release[0] += 1
        else:
            release = release[:-1]
            release[-1] += 1
        if version != None and target != None:
            upper = (target.public[0], _trim(release), -1, 0, -1, (0, 0))
            return version.public < upper
        return _legacy(version_str) < (_trim(release), True, (), "")
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
    parts = specifier.split(",")
    for part in parts:
        part = part.strip()
        if not part:
            continue
        if not _check_single(version_str, part):
            return False
    return True

def find_matching_version(specifier, candidate_versions):
    """Finds the greatest version from candidates that satisfies a specifier.

    When a dependency group lists a requirement like "numpy>=2.0", and the
    lockfile contains multiple versions of numpy (due to conflicts), this
    function determines which lockfile version the specifier refers to.

    Per pip's preference order, when multiple candidates satisfy the
    specifier, the greatest matching version is returned.

    Args:
        specifier: The version specifier string (e.g., ">=2.0", "==24.0").
        candidate_versions: A dict of {version_string: value} where the
            values are the dependency tuples from the lockfile.

    Returns:
        The matching value, or None if no candidate matches.
    """
    best_version = None
    best_value = None
    for version_str, value in candidate_versions.items():
        if version_satisfies(version_str, specifier):
            parsed = _pep440(version_str)
            key = parsed.key if parsed else _legacy(version_str)
            if best_version == None or key > best_version:
                best_version = key
                best_value = value
    return best_value
