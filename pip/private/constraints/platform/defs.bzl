"""
Helpers & constants.
"""

def supported_platform(platform_tag):
    """Predicate.

    Indicate whether the current `pip` implementation supports the platform
    represented by a given wheel platform tag. Allows for filtering out of
    wheels for currently unsupported platforms, being:

    - Android
    - iOS
    - The legacy/undefined linux_* platforms

    Args:
        platform_tag (str): A wheel platform tag

    Returns:
        bool; whether the platform is supported or not.

    """
    # We currently don't support:
    # - `linux_*` which doesn't seem standardized
    # - `android_` which could be supported but we don't have to
    # - `ios_*` which could be supported but we don't have to

    return (
        platform_tag == "any" or
        platform_tag.startswith("macosx_") or
        platform_tag.startswith("manylinux_") or
        platform_tag.startswith("musllinux_") or
        platform_tag.startswith("win")
    )
