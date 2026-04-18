"""A semver version parser.

Authored by Ignas, released as part of rules_python.
Removed in 1.5.0, so vendored and used here with thanks.
"""

def _key(version):
    """Return a comparison key for a semver version struct.

    The returned tuple follows the precedence rules defined by semver.org:
      1. major version
      2. minor version (defaulting to 0 when absent)
      3. patch version (defaulting to 0 when absent)
      4. stable releases outrank pre-releases
      5. each dot-separated pre-release identifier, where numeric identifiers
         outrank alphanumeric ones
      6. build metadata (alphabetic order)

    Args:
      version: a semver struct returned by `_new` or `semver`.

    Returns:
      A tuple that can be used for ordering and equality comparisons.
    """
    return (
        version.major,
        version.minor or 0,
        version.patch or 0,
        version.pre_release == "",
        tuple([
            (
                i if not i.isdigit() else "",
                int(i) if i.isdigit() else 0,
            )
            for i in version.pre_release.split(".")
        ]) if version.pre_release else None,
        version.build,
    )

def _to_dict(self):
    """Serialize a semver struct to a dictionary."""
    return {
        "build": self.build,
        "major": self.major,
        "minor": self.minor,
        "patch": self.patch,
        "pre_release": self.pre_release,
    }

def _upper(self):
    """Return the exclusive upper bound for a tilde (`~`) range.

    The tilde range `~X.Y.Z` allows changes that do not modify the left-most
    non-zero digit. This function bumps that digit and zeroes the rest.

    Examples:
      * `~1.2.3` -> upper bound is `1.3.0`
      * `~1.2`   -> upper bound is `1.3.0`
      * `~1`     -> upper bound is `2.0.0`

    Returns:
      A new semver struct representing the exclusive upper bound.
    """
    major = self.major
    minor = self.minor
    patch = self.patch
    build = ""
    pre_release = ""
    version = self.str()

    if patch != None:
        minor = minor + 1
        patch = 0
    elif minor != None:
        major = major + 1
        minor = 0
    elif minor == None:
        major = major + 1

    return _new(
        major = major,
        minor = minor,
        patch = patch,
        build = build,
        pre_release = pre_release,
        version = "~" + version,
    )

def _new(*, major, minor, patch, pre_release, build, version = None):
    """Create a new semver struct.

    Args:
      major:       the major version component (int).
      minor:       the minor version component (int or None).
      patch:       the patch / micro version component (int or None).
      pre_release: the pre-release identifier (str).
      build:       the build metadata (str).
      version:     the original version string (str or None).

    Returns:
      A struct representing the parsed semver with attached helper methods.
    """
    # buildifier: disable=uninitialized
    self = struct(
        major = int(major),
        minor = None if minor == None else int(minor),
        patch = None if patch == None else int(patch),
        pre_release = pre_release,
        build = build,
        # buildifier: disable=uninitialized
        key = lambda: _key(self),
        str = lambda: version,
        to_dict = lambda: _to_dict(self),
        upper = lambda: _upper(self),
    )
    return self

def semver(version):
    """Parse a semver version string and return it as a struct.

    The parsing follows the specification at https://semver.org/.

    Args:
      version: a semver version string (e.g. "1.2.3-alpha+exp.sha.5114f85").

    Returns:
      A semver struct with `major`, `minor`, `patch`, `pre_release`, `build`,
      and helper methods (`key`, `str`, `to_dict`, `upper`).
    """
    major, _, tail = version.partition(".")
    minor, _, tail = tail.partition(".")
    patch, _, build = tail.partition("+")
    patch, _, pre_release = patch.partition("-")

    return _new(
        major = int(major),
        minor = int(minor) if minor.isdigit() else None,
        patch = int(patch) if patch.isdigit() else None,
        build = build,
        pre_release = pre_release,
        version = version,
    )
