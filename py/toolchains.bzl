"""Declare toolchains"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/toolchain:repo.bzl", "toolchains_repo")

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

SCIENCE_SHA256S = {
    "linux-aarch64": "15d275395fd38357e36fd28be966bf536ad6797a43f36c0a4714847bcd81917f",
    "linux-x86_64": "db9eca979bbafa67d5498ca2a5b969fffc74a09088f1fac072a060552fc19f6d",
    "macos-aarch64": "17742d8c077339ac32479850e94d7195c2b5028415eecfbd8e076d761652c27b",
    "macos-x86_64": "f826be0d1f7e53f49d86cd33c90724ec00eaf6c8454b551826f761c43ff1b414",
}

SCIE_JUMP_SHA256S = {
    "linux-aarch64": "08855450bc52b04f70f1e9b838b2f16e27655034989a44a74b6e062d6d8492c2",
    "linux-x86_64": "da6d8f18fef078452e4b4942039fcb068e3571cf24f4c40c6cc6ec8dd67eb7fb",
    "macos-aarch64": "a17ccad392ca4437f0c9040da9c8fc98552de4c452fc4f64b21f7d1f8099829b",
    "macos-x86_64": "1226dbf8fc6c0e045b684b816eb407433c118e0555b1cde08c5df7492b1e88e7",
}

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY):
    """Create toolchain repositories for rules_py.

    Args:
        name: prefix used in created repositories
    """
    toolchains_repo(name = name)

    http_file(
        name = "rules_py_pex_2_104_1",
        urls = ["https://files.pythonhosted.org/packages/ed/91/015d90559ac5e3e7f0ef0cd9bdb1556d2617ea6ea05c2d4fce653e624484/pex-2.104.1-py3.py312-none-any.whl"],
        sha256 = "2e4006752f61de052e45d9dad2e8e3fc59b56cc41372d53618fa412f164870f4",
        downloaded_file_path = "pex-2.104.1-py3.py312-none-any.whl",
    )

    # science and scie-jump build a py_pex_binary's scie. pex 2.104.1 requires
    # science ~=0.21.0 and embeds scie-jump 1.13.0; science 0.21.1 is the first to
    # fetch the build host's scie-jump from a mirror. The scie-jump binaries are the
    # static ones, which run on any Linux libc.
    for platform, sha256 in SCIENCE_SHA256S.items():
        http_file(
            name = "rules_py_science_" + platform.replace("-", "_"),
            urls = ["https://github.com/a-scie/lift/releases/download/v0.21.1/science-fat-" + platform],
            sha256 = sha256,
            downloaded_file_path = "science",
            executable = True,
        )
    for platform, sha256 in SCIE_JUMP_SHA256S.items():
        http_file(
            name = "rules_py_scie_jump_" + platform.replace("-", "_"),
            urls = ["https://github.com/a-scie/jump/releases/download/v1.13.0/scie-jump-" + platform],
            sha256 = sha256,
            downloaded_file_path = "scie-jump",
            executable = True,
        )
