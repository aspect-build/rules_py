"""Release binary integrity hashes.

This file contents are entirely replaced during release publishing.
The checked in content is only here to allow load() statements in the sources to resolve.
"""

load("//py/private/toolchain:tools.bzl", "TOOL_CFGS", "TOOLCHAIN_PLATFORMS")

# Create a mapping for every tool name to the hash of /dev/null
NULLSHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
RELEASED_BINARY_INTEGRITY = {
    "-".join([
        tool.name,
        platform_meta.arch,
        platform_meta.vendor_os_abi,
    ]): NULLSHA
    for [platform, platform_meta] in TOOLCHAIN_PLATFORMS.items()
    for tool in TOOL_CFGS
}
