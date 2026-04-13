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
    repo_name_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
    acc = []
    for i in range(len(version)):
        ch = version[i]
        acc.append(ch if ch in repo_name_chars else "_")
    return "".join(acc)
