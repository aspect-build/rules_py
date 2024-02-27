# Declare the local Bazel workspace.
workspace(name = "aspect_rules_py")

load("//tools/release:fetch.bzl", _release_deps = "fetch_deps")
load(":internal_deps.bzl", "rules_py_internal_deps")

# Fetch deps needed only locally for development
rules_py_internal_deps()
_release_deps()

load("//py:repositories.bzl", "rules_py_dependencies")

# Fetch dependencies which users need as well
rules_py_dependencies()

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

load("@toolchains_llvm//toolchain:rules.bzl", "llvm_toolchain")

llvm_toolchain(
    name = "llvm_toolchain",
    llvm_version = "14.0.0",
    sha256 = {
        "darwin-aarch64": "1b8975db6b638b308c1ee437291f44cf8f67a2fb926eb2e6464efd180e843368",
        "linux-x86_64": "564fcbd79c991e93fdf75f262fa7ac6553ec1dd04622f5d7db2a764c5dc7fac6",
    },
    strip_prefix = {
        "darwin-aarch64": "clang+llvm-14.0.0-arm64-apple-darwin",
        "linux-x86_64": "clang+llvm-14.0.0-x86_64-linux-gnu",
    },
    sysroot = {
        "linux-aarch64": "@org_chromium_sysroot_linux_arm64//:sysroot",
        "linux-x86_64": "@org_chromium_sysroot_linux_x86_64//:sysroot",
        "darwin-aarch64": "@sysroot_darwin_universal//:sysroot",
        "darwin-x86_64": "@sysroot_darwin_universal//:sysroot",
    },
    urls = {
        "darwin-aarch64": ["https://github.com/aspect-forks/llvm-project/releases/download/aspect-release-14.0.0/clang+llvm-14.0.0-arm64-apple-darwin.tar.xz"],
        "linux-x86_64": ["https://github.com/aspect-forks/llvm-project/releases/download/aspect-release-14.0.0/clang+llvm-14.0.0-x86_64-linux-gnu.tar.xz"],
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
    versions = [
        "1.74.1",
    ],
)

# Declare cross-compilation toolchains
rust_repository_set(
    name = "linux_x86_64",
    edition = "2021",
    # release builds take place on GitHub actions: linux x86
    exec_triple = "x86_64-unknown-linux-gnu",
    # and cross-compile to these platforms:
    extra_target_triples = [
        "aarch64-unknown-linux-gnu",
        "x86_64-apple-darwin",
        "aarch64-apple-darwin",
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
