"""Repository rule for auto-detecting host libc variant.

This module provides a repository rule that detects whether the host system
uses glibc or musl, and generates a repository that exposes this information
to the Bazel build configuration.
"""

def _libc_detector_impl(repository_ctx):
    """Detect libc variant and generate configuration repository."""
    
    # Try to detect libc using multiple methods
    libc = "unknown"
    
    # Method 1: ldd --version
    ldd_result = repository_ctx.execute(["ldd", "--version"])
    if ldd_result.return_code == 0:
        output = (ldd_result.stdout + ldd_result.stderr).lower()
        if "musl" in output:
            libc = "musl"
        elif "gnu" in output or "glibc" in output:
            libc = "glibc"
    
    # Method 2: Check for Alpine in /etc/os-release
    if libc == "unknown":
        os_release = repository_ctx.execute(["cat", "/etc/os-release"])
        if os_release.return_code == 0:
            if "alpine" in os_release.stdout.lower():
                libc = "musl"
    
    # Generate the repository
    repository_ctx.file("BUILD.bazel", """# Auto-generated libc detection
# Detected libc: {libc}

package(default_visibility = ["//visibility:public"])

config_setting(
    name = "is_glibc",
    values = {{"define": "libc=glibc"}},
)

config_setting(
    name = "is_musl",
    values = {{"define": "libc=musl"}},
)

# Export the detected value as a Starlark constant
libc_variant = "{libc}"
""".format(libc = libc))
    
    repository_ctx.file("defs.bzl", """# Auto-generated libc detection
LIBC_VARIANT = "{libc}"
""".format(libc = libc))
    
    # Print detection result for debugging
    print("UV libc detection: detected {} libc".format(libc))

libc_detector = repository_rule(
    implementation = _libc_detector_impl,
    doc = """Auto-detects the host libc variant (glibc vs musl).
    
    Creates a repository that exposes the detected libc type, which can be
    used to select compatible wheels (manylinux for glibc, musllinux for musl).
    
    Example:
        libc_detector(name = "uv_libc_detection")
        
        # In BUILD files:
        load("@uv_libc_detection//:defs.bzl", "LIBC_VARIANT")
    """,
)
