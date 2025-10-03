load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

TOOLS = [
    struct(
        os = "osx",
        arch = "aarch64",
        libc = "libsystem",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_aarch64_apple_darwin",
        sha256 = "a7648d1728cfb80e99553fcf4c4f4da72aa02d869192712eba8e61b86b237e0b",
    ),
    struct(
        os = "osx",
        arch = "x86_64",
        libc = "libsystem",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_x86_64_apple_darwin",
        sha256 = "cb54250ce1393f95d080425df9e4ac926df75ed3b4f10c0642458c7b9697beb4",
    ),
    struct(
        os = "linux",
        arch = "aarch64",
        libc = "gnu",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_aarch64_unknown_linux_gnu",
        sha256 = "b0790b06d69c62163689bc10dccdcb9909b88c235f6538e0bd6357247c63db47",
    ),
    struct(
        os = "linux",
        arch = "aarch64",
        libc = "musl",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_aarch64_unknown_linux_musl",
        sha256 = "f303b3b1d63529d9e82b9ef19fd711f90d8fd87d4a860b383a9453bac3369139",
    ),
    struct(
        os = "linux",
        arch = "x86_64",
        libc = "gnu",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_x86_64_unknown_linux_gnu",
        sha256 = "4d9426b620acffe73af53e5524ed8c8bbe15e6214c752f37c22f5479fc9e3a51",
    ),
    struct(
        os = "linux",
        arch = "x86_64",
        libc = "musl",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_x86_64_unknown_linux_musl",
        sha256 = "c9b2a29dca81a4ceff9aa40049b8e5d7fafd4981f8460e81c2b3c529b95a9afa",
    )
]

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
        if "glibc" in ldd:
            return "gnu"
        elif "musl" in ldd:
            return "musl"

    return None
    
def _tomltool_impl(repository_ctx):
    arch = _translate_cpu(repository_ctx.os.arch)
    os = _translate_os(repository_ctx.os.name)
    libc = _translate_libc(repository_ctx)

    found = False
    for tool in TOOLS:
        if tool.arch == arch and tool.os == os and tool.libc == libc:
            found = True
            http_file(
                name = "tomltool",
                url = tool.url,
                sha256 = tool.sha256,
                executable = True,
            )


tomltool = module_extension(
    implementation = _tomltool_impl,
    tag_classes = {}
)
