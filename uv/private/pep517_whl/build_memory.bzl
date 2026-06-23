"""Validation shared by wheel build configuration surfaces."""

# bazel-lib 3.2 clamps larger resource requests to 32 GiB:
# https://github.com/aspect-build/bazel-lib/blob/v3.2.0/lib/private/resource_sets.bzl#L2224-L2227
MAX_BUILD_MEMORY_MB = 32768

def validate_build_memory_mb(value, owner):
    if value < 0 or value > MAX_BUILD_MEMORY_MB:
        fail("{}: build_memory_mb must be between 0 and {}".format(
            owner,
            MAX_BUILD_MEMORY_MB,
        ))
