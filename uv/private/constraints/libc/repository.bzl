"""Repository rule for auto-detecting the host libc variant.

This module provides a repository rule that detects whether the host system
uses glibc or musl, and generates an external repository that exposes this
information to the Bazel build configuration.

Detection heuristics (executed during repository fetch, i.e. on the Bazel
client host, NOT on a remote execution worker):
    1. Inspect the output of ``ldd --version`` for "musl", "gnu" or "glibc".
    2. Fall back to reading ``/etc/os-release`` and look for "alpine".

Fragility notes:
    - The detection runs via ``repository_ctx.execute`` on the machine that
      performs the external repository fetch. Under Remote Build Execution
      (RBE) this is the client host, not the execution worker. Cross-compiling
      from glibc to musl (or vice-versa) will therefore report the wrong libc
      for the target platform.
    - If both heuristics fail the result silently falls back to ``"unknown"``,
      which can break wheel selection downstream because no platform tag will
      match.
    - The generated ``config_setting`` targets use ``--define libc=...``,
      which is orthogonal to the ``constraint_value`` / ``constraint_setting``
      declared statically in ``libc/BUILD.bazel``. The two mechanisms are not
      wired together, so selects that use one will not see the other.
"""

def _libc_detector_impl(repository_ctx):
    """Detect libc variant and emit the external repository files.

    Executes host-side commands to distinguish glibc from musl, then writes
    a BUILD file with ``config_setting`` targets and a defs.bzl file that
    exports the detected value as a Starlark constant.

    Args:
        repository_ctx: The repository context provided by Bazel.
    """
    libc = "unknown"

    ldd_result = repository_ctx.execute(["ldd", "--version"])
    if ldd_result.return_code == 0:
        output = (ldd_result.stdout + ldd_result.stderr).lower()
        if "musl" in output:
            libc = "musl"
        elif "gnu" in output or "glibc" in output:
            libc = "glibc"

    if libc == "unknown":
        os_release = repository_ctx.execute(["cat", "/etc/os-release"])
        if os_release.return_code == 0:
            if "alpine" in os_release.stdout.lower():
                libc = "musl"

    repository_ctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

config_setting(
    name = "is_glibc",
    values = {{"define": "libc=glibc"}},
)

config_setting(
    name = "is_musl",
    values = {{"define": "libc=musl"}},
)

libc_variant = "{libc}"
""".format(libc = libc))

    repository_ctx.file("defs.bzl", """LIBC_VARIANT = "{libc}"
""".format(libc = libc))

    print("UV libc detection: detected {} libc".format(libc))

libc_detector = repository_rule(
    implementation = _libc_detector_impl,
    doc = """Auto-detects the host libc variant (glibc vs musl).

Creates an external repository that exposes the detected libc type. The
repository contains:

- ``is_glibc`` and ``is_musl`` config_setting targets keyed on
  ``--define libc=glibc`` / ``--define libc=musl``.
- ``defs.bzl`` exporting ``LIBC_VARIANT`` as a string constant.

Example:
    libc_detector(name = "uv_libc_detection")

    load("@uv_libc_detection//:defs.bzl", "LIBC_VARIANT")
""",
)
