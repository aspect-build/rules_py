"""TOML decoding utilities for aspect_rules_py.

This module provides a Starlark API for parsing TOML files by invoking a
platform-specific `toml2json` binary. It detects the host platform (CPU,
operating system, and C library) to select the correct toolchain binary,
then converts the TOML content into a native Starlark dictionary.
"""

def _translate_cpu(arch):
    """Normalizes a host CPU architecture name to a canonical label.

    Args:
        arch: The CPU architecture string reported by the host.

    Returns:
        A canonical architecture string (e.g. "x86_64", "aarch64"), or None
        if the architecture is not recognized.
    """
    if arch in ["i386", "i486", "i586", "i686", "i786", "x86"]:
        return "x86_32"
    if arch in ["amd64", "x86_64", "x64"]:
        return "x86_64"
    if arch in ["ppc", "ppc64"]:
        return "ppc"
    if arch in ["ppc64le"]:
        return "ppc64le"
    if arch in ["arm", "armv7l"]:
        return "arm"
    if arch in ["aarch64"]:
        return "aarch64"
    if arch in ["s390x", "s390"]:
        return "s390x"
    if arch in ["mips64el", "mips64"]:
        return "mips64"
    if arch in ["riscv64"]:
        return "riscv64"
    return None

def _translate_os(os):
    """Normalizes a host operating system name to a canonical label.

    Args:
        os: The operating system string reported by the host.

    Returns:
        A canonical OS string (e.g. "linux", "osx", "windows"), or None if
        the operating system is not recognized.
    """
    if os.startswith("mac os"):
        return "osx"
    if os.startswith("freebsd"):
        return "freebsd"
    if os.startswith("openbsd"):
        return "openbsd"
    if os.startswith("linux"):
        return "linux"
    if os.startswith("windows"):
        return "windows"
    return None

def _translate_libc(repository_ctx):
    """Detects the host C library implementation.

    On Linux this function runs `ldd --version` to distinguish between
    glibc-based and musl-based systems. On macOS and Windows the result is
    inferred from the operating system.

    If ldd is missing or fails (common in Alpine containers or NixOS),
    the function falls back to assuming glibc, which is the de facto
    standard for the vast majority of Linux distributions.

    Args:
        repository_ctx: A Bazel repository context.

    Returns:
        A libc identifier string (e.g. "gnu", "musl", "libsystem", "msvc"),
        or None if the implementation cannot be determined.
    """
    os = _translate_os(repository_ctx.os.name)
    if os == "osx":
        return "libsystem"

    elif os == "linux":
        res = repository_ctx.execute(["ldd", "--version"])
        if res.return_code == 0:
            ldd = res.stdout.lower()
            if "gnu" in ldd or "glibc" in ldd:
                return "gnu"
            elif "musl" in ldd:
                return "musl"
        return "gnu"

    elif os == "windows":
        return "msvc"

    return None

def _decode_file(ctx, content_path):
    """Parses a TOML file and returns its content as a Starlark dictionary.

    Platform detection is used to locate the correct `toml2json` binary.
    The file is watched so that Bazel invalidates the cache when it changes.
    If decoding fails, None is returned so the caller can handle the error.

    Args:
        ctx: A Bazel module or repository context.
        content_path: The path to the TOML file to decode.

    Returns:
        A Starlark dict representing the parsed TOML content, or None if the
        binary exits with a non-zero status.
    """
    arch = _translate_cpu(ctx.os.arch)
    os = _translate_os(ctx.os.name)
    libc = _translate_libc(ctx)

    ctx.watch(content_path)

    out = ctx.execute(
        [
            Label("@toml2json_{}_{}_{}//file:downloaded".format(arch, os, libc)),
            content_path,
        ],
    )
    if out.return_code == 0:
        return json.decode(out.stdout)

    else:
        return None

toml = struct(
    decode_file = _decode_file,
)
