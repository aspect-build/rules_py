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

load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")

python_register_toolchains(
    name = "python_toolchain_3_8",
    python_version = "3.8.12",
    # Setting `set_python_version_constraint` will set special constraints on the registered toolchain.
    # This means that this toolchain registration will only be selected for `py_binary` / `py_test` targets
    # that have the `python_version = "3.8.12"` attribute set. Targets that have no `python_attribute` will use
    # the default toolchain resolved which can be seen below.
    set_python_version_constraint = True,
)

# It is important to register the default toolchain at last as it will be selected for any
# py_test/py_binary target even if it has python_version attribute set.
python_register_toolchains(
    name = "python_toolchain",
    python_version = "3.9",
)

py_repositories()

############################################
# Aspect bazel-lib
load("@aspect_bazel_lib//lib:repositories.bzl", "register_coreutils_toolchains", "register_expand_template_toolchains")

register_coreutils_toolchains()

register_expand_template_toolchains()

load("@musl_toolchains//:repositories.bzl", "load_musl_toolchains")

load_musl_toolchains(extra_target_compatible_with = ["@//tools/linkers:musl"])

load("@musl_toolchains//:toolchains.bzl", "register_musl_toolchains")

register_musl_toolchains()

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

load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")

############################################
# Gazelle, for generating bzl_library targets
load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")

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
# rules_rust dependencies for building tools
load("@rules_rust//rust:repositories.bzl", "rules_rust_dependencies", "rust_register_toolchains", "rust_repository_set")

rules_rust_dependencies()

RUST_EDITION = "2021"

RUST_VERSION = "1.81.0"

# Declare cross-compilation toolchains
rust_repository_set(
    name = "apple_darwin_aarch64",
    edition = RUST_EDITION,
    exec_triple = "aarch64-apple-darwin",
    # and cross-compile to these platforms:
    extra_target_triples = {
        "aarch64-apple-darwin": [
            "@platforms//cpu:arm64",
            "@platforms//os:macos",
        ],
        "aarch64-unknown-linux-musl": [
            "@platforms//cpu:arm64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
        "x86_64-apple-darwin": [
            "@platforms//cpu:x86_64",
            "@platforms//os:macos",
        ],
        "x86_64-unknown-linux-musl": [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
    },
    versions = [RUST_VERSION],
)

rust_repository_set(
    name = "apple_darwin_x86_64",
    edition = RUST_EDITION,
    exec_triple = "x86_64-apple-darwin",
    # and cross-compile to these platforms:
    extra_target_triples = {
        "aarch64-apple-darwin": [
            "@platforms//cpu:arm64",
            "@platforms//os:macos",
        ],
        "aarch64-unknown-linux-musl": [
            "@platforms//cpu:arm64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
        "x86_64-apple-darwin": [
            "@platforms//cpu:x86_64",
            "@platforms//os:macos",
        ],
        "x86_64-unknown-linux-musl": [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
    },
    versions = [RUST_VERSION],
)

rust_repository_set(
    name = "rust_linux_x86_64",
    edition = RUST_EDITION,
    exec_triple = "x86_64-unknown-linux-gnu",
    extra_target_triples = {
        "aarch64-unknown-linux-gnu": [
            "@platforms//cpu:arm64",
            "@platforms//os:linux",
            "@//tools/linkers:unknown",
        ],
        "aarch64-unknown-linux-musl": [
            "@platforms//cpu:arm64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
        "x86_64-unknown-linux-gnu": [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
            "@//tools/linkers:unknown",
        ],
        "x86_64-unknown-linux-musl": [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
    },
    versions = [RUST_VERSION],
)

rust_repository_set(
    name = "rust_linux_aarch64",
    edition = RUST_EDITION,
    exec_triple = "aarch64-unknown-linux-gnu",
    extra_target_triples = {
        "aarch64-unknown-linux-gnu": [
            "@platforms//cpu:arm64",
            "@platforms//os:linux",
            "@//tools/linkers:unknown",
        ],
        "aarch64-unknown-linux-musl": [
            "@platforms//cpu:arm64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
        "x86_64-unknown-linux-gnu": [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
            "@//tools/linkers:unknown",
        ],
        "x86_64-unknown-linux-musl": [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
            "@//tools/linkers:musl",
        ],
    },
    versions = [RUST_VERSION],
)

rust_register_toolchains(
    edition = RUST_EDITION,
    versions = [RUST_VERSION],
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
        "//py/tools/unpack_bin:Cargo.toml",
        "//py/tools/venv_bin:Cargo.toml",
        "//py/tools/venv_shim:Cargo.toml",
    ],
)

load("@crate_index//:defs.bzl", "crate_repositories")

crate_repositories()

load("@rules_oci//oci:dependencies.bzl", "rules_oci_dependencies")

rules_oci_dependencies()

load("@rules_oci//oci:repositories.bzl", "oci_register_toolchains")

oci_register_toolchains(name = "oci")

# You can pull your base images using oci_pull like this:
load("@rules_oci//oci:pull.bzl", "oci_pull")

oci_pull(
    name = "ubuntu",
    digest = "sha256:b59d21599a2b151e23eea5f6602f4af4d7d31c4e236d22bf0b62b86d2e386b8f",
    image = "ubuntu",
    platforms = [
        "linux/arm64/v8",
        "linux/amd64",
    ],
    tag = "latest",
)

load("@container_structure_test//:repositories.bzl", "container_structure_test_register_toolchain")

container_structure_test_register_toolchain(name = "cst")
