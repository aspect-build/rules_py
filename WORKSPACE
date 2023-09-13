# Declare the local Bazel workspace.
workspace(name = "aspect_rules_py")

load(":internal_deps.bzl", "rules_py_internal_deps")

# Fetch deps needed only locally for development
rules_py_internal_deps()

load("//py:repositories.bzl", "rules_py_dependencies")

# Fetch dependencies which users need as well
rules_py_dependencies()

# Load the Python toolchain for rules_docker
register_toolchains("//:container_py_toolchain")

load("@rules_python//python:repositories.bzl", "python_register_toolchains")

python_register_toolchains(
    name = "python_toolchain",
    python_version = "3.9",
)

############################################
# Aspect gcc toolchain
load("@aspect_gcc_toolchain//toolchain:repositories.bzl", "gcc_toolchain_dependencies")

gcc_toolchain_dependencies()

load("@aspect_gcc_toolchain//toolchain:defs.bzl", "ARCHS", "gcc_register_toolchain")

gcc_register_toolchain(
    name = "gcc_toolchain_x86_64",
    target_arch = ARCHS.x86_64,
)

############################################
# Development dependencies from pypi
load("@python_toolchain//:defs.bzl", "interpreter")
load(":internal_python_deps.bzl", "rules_py_internal_pypi_deps")

rules_py_internal_pypi_deps(
    interpreter = interpreter,
)

load("@pypi//:requirements.bzl", "install_deps")

install_deps()

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
