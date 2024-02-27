"Macros for creating release binaries"

PLATFORMS = [
    struct(os = "darwin", arch = "aarch64")
]

def multi_platform_rust_binaries(name):
