"""Constraints and detection for libc variants (glibc vs musl).

This module provides detection and constraint settings for distinguishing
between GNU C Library (glibc) and musl libc, which is essential for
selecting compatible wheels (manylinux vs musllinux).

In PEP 508, there is no marker for libc type, but wheels use platform
tags that distinguish them (manylinux_* for glibc, musllinux_* for musl).
"""

# Valid libc types
LIBC_TYPES = [
    "glibc",  # GNU C Library (manylinux wheels)
    "musl",   # musl libc (musllinux wheels)
    "unknown",
]

def detect_libc(repository_ctx):
    """Detect the libc variant of the host system.
    
    Uses multiple heuristics to determine if the system is using glibc or musl:
    1. Check ldd --version output
    2. Check for musl-specific files
    3. Check /etc/os-release for Alpine
    
    Args:
        repository_ctx: The repository context
        
    Returns:
        One of "glibc", "musl", or "unknown"
    """
    # Method 1: ldd --version
    ldd_result = repository_ctx.execute(["ldd", "--version"])
    if ldd_result.return_code == 0:
        output = (ldd_result.stdout + ldd_result.stderr).lower()
        if "musl" in output:
            return "musl"
        elif "gnu" in output or "glibc" in output:
            return "glibc"
    
    # Method 2: Check for musl-specific ldconfig
    musl_check = repository_ctx.execute(["which", "ld-musl-$(uname -m).so.1"])
    if musl_check.return_code == 0:
        return "musl"
    
    # Method 3: Check /etc/os-release for Alpine
    os_release = repository_ctx.execute(["cat", "/etc/os-release"])
    if os_release.return_code == 0:
        if "alpine" in os_release.stdout.lower():
            return "musl"
    
    return "unknown"

def select_wheel_by_libc(wheels, libc):
    """Filter wheels by libc compatibility.
    
    Args:
        wheels: List of wheel filenames
        libc: One of "glibc", "musl", or "unknown"
        
    Returns:
        List of wheels compatible with the libc
    """
    if libc == "musl":
        # Prefer musllinux wheels for musl systems
        musl_wheels = [w for w in wheels if "musllinux" in w]
        if musl_wheels:
            return musl_wheels
        # Fall back to any if no musl-specific wheels
        return [w for w in wheels if "manylinux" not in w]
    elif libc == "glibc":
        # Prefer manylinux wheels for glibc systems
        glibc_wheels = [w for w in wheels if "manylinux" in w]
        if glibc_wheels:
            return glibc_wheels
        # Fall back to any if no manylinux wheels
        return [w for w in wheels if "musllinux" not in w]
    else:
        # Unknown libc: return all wheels
        return wheels

def get_libc_from_platform_tag(platform_tag):
    """Infer libc type from a wheel platform tag.
    
    Args:
        platform_tag: A platform tag like "manylinux_2_17_x86_64" or "musllinux_1_1_x86_64"
        
    Returns:
        One of "glibc", "musl", or None
    """
    if platform_tag.startswith("manylinux_"):
        return "glibc"
    elif platform_tag.startswith("musllinux_"):
        return "musl"
    return None
