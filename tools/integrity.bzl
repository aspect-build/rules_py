"""Release binary integrity hashes.

This file contents are entirely replaced during release publishing.
The checked in content is only here to allow load() statements in the sources to resolve.
"""

# buildifier: disable=bzl-visibility
# Since this is a load from private despite it being our private
load("//py/private/toolchain:tools.bzl", "TOOLCHAIN_PLATFORMS", "TOOL_CFGS")

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
