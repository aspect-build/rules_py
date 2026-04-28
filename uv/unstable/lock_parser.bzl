"""Minimal parser for uv.lock files to extract package wheel URLs.

Parses the specific subset of TOML produced by `uv lock` to extract package
names and per-platform wheel download URLs. This is not a general TOML parser;
it relies on the fixed structure that uv always generates.

Limitations:
    - Assumes each wheel entry fits on a single line (true for uv-generated locks).
    - Does not handle multi-line TOML arrays inside a [[package]] block.
    - Packages with no wheels (sdist-only) are omitted when wheels_only=True.
"""

def _extract_quoted(s, key):
    """Return the first double-quoted value for `key = "..."` in string s."""
    prefix = key + ' = "'
    start = s.find(prefix)
    if start < 0:
        return ""
    start += len(prefix)
    end = s.find('"', start)
    if end < 0:
        return ""
    return s[start:end]

def _parse_package_block(block):
    """Parse one [[package]] section into a list of per-wheel dicts."""
    name = _extract_quoted(block, "name")
    if not name:
        return []

    wheels_start = block.find("wheels = [")
    if wheels_start < 0:
        return [{"name": name, "url": "", "sha256": ""}]

    wheels_end = block.find("]", wheels_start + len("wheels = ["))
    if wheels_end < 0:
        return [{"name": name, "url": "", "sha256": ""}]

    wheels_section = block[wheels_start:wheels_end]
    result = []

    for line in wheels_section.split("\n"):
        if 'url = "' not in line:
            continue
        url = _extract_quoted(line, "url")
        if not url:
            continue
        sha256 = ""
        hash_val = _extract_quoted(line, "hash")
        if hash_val.startswith("sha256:"):
            sha256 = hash_val[len("sha256:"):]
        result.append({"name": name, "url": url, "sha256": sha256})

    if not result:
        return [{"name": name, "url": "", "sha256": ""}]

    return result

def parse_uv_lock(content, wheels_only = True):
    """Parse a uv.lock file and return a list of package dicts.

    Args:
        content: The raw string content of a uv.lock file.
        wheels_only: When True (default), omit entries that have no wheel URL.

    Returns:
        A list of dicts, each with keys:
            name   - package name as it appears in the lock file
            url    - wheel download URL, or "" for sdist-only packages
            sha256 - sha256 hash string (without "sha256:" prefix), or ""
    """
    packages = []
    for part in content.split("[[package]]")[1:]:
        for pkg in _parse_package_block(part):
            if wheels_only and not pkg["url"]:
                continue
            packages.append(pkg)
    return packages
