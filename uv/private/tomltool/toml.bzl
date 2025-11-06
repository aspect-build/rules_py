"""

"""

# Ripped from the platforms library
def _translate_cpu(arch):
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
    os = _translate_os(repository_ctx.os.name)
    if os == "osx":
        return "libsystem"

    elif os == "linux":
        ldd = repository_ctx.execute(["ldd", "--version"]).stdout.lower()
        if "gnu" in ldd or "glibc" in ldd:
            return "gnu"

        elif "musl" in ldd:
            return "musl"

    return None

def _decode_file(ctx, content_path):
    # Note that ctx is either the repository_ctx or maybe the module_ctx
    arch = _translate_cpu(ctx.os.arch)
    os = _translate_os(ctx.os.name)
    libc = _translate_libc(ctx)

    out = ctx.execute(
        [
            Label("@toml2json_{}_{}_{}//file:downloaded".format(arch, os, libc)),
            content_path,
        ],
    )
    if out.return_code == 0:
        return json.decode(out.stdout)

    else:
        fail("Unable to decode TOML file %s" % content_path)

toml = struct(
    decode_file = _decode_file,
)
