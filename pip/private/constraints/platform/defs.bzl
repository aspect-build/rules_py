def supported_platform(platform_tag):
    # We currently don't support:
    # - `linux_*` which doesn't seem standardized
    # - `android_` which could be supported but we don't have to
    # - `ios_*` which could be supported but we don't have to

    return (
        platform_tag == "any"
        or platform_tag.startswith("macosx_")
        or platform_tag.startswith("manylinux_")
        or platform_tag.startswith("musllinux_")
        or platform_tag.startswith("win")
    )
        
