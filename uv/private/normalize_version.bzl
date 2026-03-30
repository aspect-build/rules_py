"""
Normalize a PEP 440 version string for use in Bazel repository names.
"""

def normalize_version(version):
    """Normalize a PEP 440 version string to a valid Bazel repo name component.

    Replaces characters that are valid in PEP 440 version strings but not in
    Bazel repository names.

    Args:
        version: str, the PEP 440 version string.

    Returns:
        a normalized version as a string.
    """
    return version.replace(".", "_").replace("+", "_")
