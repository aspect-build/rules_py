# Declare the local Bazel workspace.
workspace(name = "aspect_rules_py")

load("//tools/release:fetch.bzl", _release_deps = "fetch_deps")
load(":internal_deps.bzl", "rules_py_internal_deps")

# Fetch deps needed only locally for development
rules_py_internal_deps()

# Fetch deps needed only for a release.
_release_deps()

load("//py:repositories.bzl", "rules_py_dependencies")

# Fetch dependencies which users need as well
rules_py_dependencies()

load("//py:toolchains.bzl", "rules_py_toolchains")

rules_py_toolchains()

# Load the Python toolchain for rules_docker
register_toolchains("//:container_py_toolchain")

load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")

python_register_toolchains(
    name = "python_toolchain",
    python_version = "3.9",
)

py_repositories()

############################################
# Aspect bazel-lib
load("@aspect_bazel_lib//lib:repositories.bzl", "register_coreutils_toolchains")

register_coreutils_toolchains()

############################################
## CC toolchain using llvm
load("@toolchains_llvm//toolchain:deps.bzl", "bazel_toolchain_dependencies")

bazel_toolchain_dependencies()

load("@toolchains_llvm//toolchain:rules.bzl", "llvm_toolchain")

llvm_toolchain(
    name = "llvm_toolchain",
    llvm_version = "17.0.2",
    sha256 = {
        "darwin-aarch64": "bb5144516c94326981ec78c8b055c85b1f6780d345128cae55c5925eb65241ee",
        "darwin-x86_64": "800ec8401344a95f84588815e97523a0ed31fd05b6ffa9e1b58ce20abdcf69f1",
        "linux-aarch64": "49eec0202b8cd4be228c8e92878303317f660bc904cf6e6c08917a55a638917d",
        "linux-x86_64": "0c5096c157e196a04fc6ac58543266caef0da3e3c921414a7c279feacc2309d9",
    },
    sysroot = {
        "darwin-aarch64": "@sysroot_darwin_universal//:sysroot",
        "darwin-x86_64": "@sysroot_darwin_universal//:sysroot",
        "linux-aarch64": "@org_chromium_sysroot_linux_arm64//:sysroot",
        "linux-x86_64": "@org_chromium_sysroot_linux_x86_64//:sysroot",
    },
    urls = {
        "darwin-aarch64": ["https://github.com/dzbarsky/static-clang/releases/download/v17.0.2-8/darwin_arm64_minimal.tar.xz"],
        "darwin-x86_64": ["https://github.com/dzbarsky/static-clang/releases/download/v17.0.2-8/darwin_amd64_minimal.tar.xz"],
        "linux-aarch64": ["https://github.com/dzbarsky/static-clang/releases/download/v17.0.2-8/linux_arm64_minimal.tar.xz"],
        "linux-x86_64": ["https://github.com/dzbarsky/static-clang/releases/download/v17.0.2-8/linux_amd64_minimal.tar.xz"],
    },
)

load("@llvm_toolchain//:toolchains.bzl", "llvm_register_toolchains")

llvm_register_toolchains()

############################################
# Development dependencies from pypi
load("@python_toolchain//:defs.bzl", "interpreter")
load(":internal_python_deps.bzl", "rules_py_internal_pypi_deps")

rules_py_internal_pypi_deps(
    interpreter = interpreter,
)

load("@pypi//:requirements.bzl", "install_deps")

install_deps()

load("@django//:requirements.bzl", install_django_deps = "install_deps")

install_django_deps()

################################
# For running our own unit tests
load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")

bazel_skylib_workspace()

############################################
# Gazelle, for generating bzl_library targets
load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")

go_rules_dependencies()

go_register_toolchains(version = "1.19.3")

gazelle_dependencies()

load("@rules_python//gazelle:deps.bzl", _py_gazelle_deps = "gazelle_deps")

_py_gazelle_deps()

load("@bazel_skylib_gazelle_plugin//:workspace.bzl", "bazel_skylib_gazelle_plugin_workspace")

bazel_skylib_gazelle_plugin_workspace()

load("@bazel_skylib_gazelle_plugin//:setup.bzl", "bazel_skylib_gazelle_plugin_setup")

bazel_skylib_gazelle_plugin_setup(register_go_toolchains = False)

############################################
# rules_docker dependencies for containers
load(
    "@io_bazel_rules_docker//repositories:repositories.bzl",
    container_repositories = "repositories",
)

container_repositories()

load(
    "@io_bazel_rules_docker//python3:image.bzl",
    _py_image_repos = "repositories",
)

_py_image_repos()

############################################
# rules_rust dependencies for building tools
load("@rules_rust//rust:repositories.bzl", "rules_rust_dependencies", "rust_register_toolchains", "rust_repository_set")

rules_rust_dependencies()

rust_register_toolchains(
    edition = "2021",
    extra_target_triples = [
        "x86_64-apple-darwin",
    ],
    versions = [
        "1.74.1",
    ],
)

# Declare cross-compilation toolchains
rust_repository_set(
    name = "apple_darwin_86_64",
    edition = "2021",
    exec_triple = "x86_64-apple-darwin",
    # and cross-compile to these platforms:
    extra_target_triples = [
        "aarch64-apple-darwin",
    ],
    versions = ["1.74.1"],
)

rust_repository_set(
    name = "linux_x86_64",
    edition = "2021",
    exec_triple = "x86_64-unknown-linux-gnu",
    # and cross-compile to these platforms:
    extra_target_triples = [
        "aarch64-unknown-linux-gnu",
    ],
    versions = ["1.74.1"],
)

load("@rules_rust//crate_universe:repositories.bzl", "crate_universe_dependencies")

crate_universe_dependencies()

load("@rules_rust//crate_universe:defs.bzl", "crates_repository")

crates_repository(
    name = "crate_index",
    cargo_lockfile = "//:Cargo.lock",
    lockfile = "//:Cargo.Bazel.lock",
    manifests = [
        "//:Cargo.toml",
        "//py/tools/py:Cargo.toml",
        "//py/tools/venv_bin:Cargo.toml",
        "//py/tools/unpack_bin:Cargo.toml",
    ],
)

load("@crate_index//:defs.bzl", "crate_repositories")

crate_repositories()
