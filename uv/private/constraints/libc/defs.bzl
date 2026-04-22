"""Constraints and detection for libc variants (glibc vs musl).

This module provides a reusable ``detect_libc`` function and the canonical
list of libc types. It is intended to be imported by repository rules or
other Starlark code that needs host-side libc detection without reimplementing
the heuristics.

Known problems:
    - The detection logic here is duplicated (with slight drift) in
      ``repository.bzl`` in the same package. Any fix to one must be ported
      to the other or the results will diverge.
    - ``repository_ctx.execute`` runs on the Bazel client host during
      repository fetch, not on a remote execution worker. Under RBE or
      cross-compilation the detected libc describes the client machine,
      not the target platform.
    - If every heuristic fails the function silently returns ``"unknown"``,
      which can break downstream wheel selection because no platform tag
      matches an unknown libc.
"""

LIBC_TYPES = [
    "glibc",
    "musl",
    "unknown",
]

def detect_libc(repository_ctx):
    """Detect the libc variant of the host system.

    Executes three heuristics in order:
        1. Inspect ``ldd --version`` for "musl", "gnu" or "glibc".
        2. Look for the musl dynamic linker via
           ``which ld-musl-$(uname -m).so.1``.
        3. Read ``/etc/os-release`` and check for "alpine".

    Args:
        repository_ctx: The repository context provided by Bazel.

    Returns:
        One of ``"glibc"``, ``"musl"``, or ``"unknown"``.
    """
    ldd_result = repository_ctx.execute(["ldd", "--version"])
    if ldd_result.return_code == 0:
        output = (ldd_result.stdout + ldd_result.stderr).lower()
        if "musl" in output:
            return "musl"
        elif "gnu" in output or "glibc" in output:
            return "glibc"

    musl_check = repository_ctx.execute(["which", "ld-musl-$(uname -m).so.1"])
    if musl_check.return_code == 0:
        return "musl"

    os_release = repository_ctx.execute(["cat", "/etc/os-release"])
    if os_release.return_code == 0:
        if "alpine" in os_release.stdout.lower():
            return "musl"

    return "unknown"
