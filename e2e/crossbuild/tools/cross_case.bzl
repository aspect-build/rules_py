"""Shared scaffolding for a "build one real package for amd64+arm64, then
actually run it" e2e/crossbuild case.

Every case here cross-compiles a package from the same amd64 exec host for
linux/amd64 and linux/arm64, then runs both — QEMU for arm64 — via
container_structure_test, plus a per-arch structural check (ELF machine,
and, where the .so's own filename carries one, its cpython ABI tag). This
macro is the ~90 lines every case shared verbatim; anything genuinely
case-specific (extra data deps, a diff-against-a-reference-wheel test
instead of a command test, macOS coverage) stays hand-written — see
//geohash and //zstandard, which aren't built from this macro for exactly
that reason.
"""

load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer")
load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@container_structure_test//:defs.bzl", "container_structure_test")
load("@rules_oci//oci:defs.bzl", "oci_image")
load(":checks.bzl", "assert_so_arch", "assert_so_suffix")

def pep517_cross_case(name, deps, so_pattern, check_so_suffix = True, main = None, dep_group = None, image_command_test_config = None):
    """Declares the amd64/arm64 build+run scaffolding for one e2e/crossbuild package.

    Produces (all unprefixed, matching the package's own BUILD.bazel):
    "<name>_bin", "layers", "{amd64,arm64}_layers", "<name>_so_arch_{amd64,arm64}_test",
    "<name>_so_suffix_{amd64,arm64}_test" (if check_so_suffix), "image",
    "{amd64,arm64}_image", "{amd64,arm64}_command_test".

    Args:
        name: the package's own directory/case name, e.g. "bcrypt". Only
            used to derive default filenames/labels below — every produced
            target keeps its existing unprefixed name (":layers", not
            ":<name>_layers"), so migrating a case onto this macro doesn't
            rename anything CI or a human already refers to.
        deps: the py_binary's deps — the hub's target package, e.g.
            ["@pypi_crossbuild_bcrypt//bcrypt"].
        so_pattern: grep -E pattern matching the compiled .so's path inside
            the squashed tar (see //tools:checks.bzl).
        check_so_suffix: whether the .so's filename carries a cpython
            version/ABI tag worth asserting. False for ctypes-loaded .so's
            (awkward_cpp), abi3 builds (psutil), or an unsuffixed .so
            (jpype1's _jpype.so).
        main: py_binary's main/srcs file; defaults to "<name>_main.py".
        dep_group: py_binary's dep_group; defaults to "crossbuild_<name>".
        image_command_test_config: the container_structure_test YAML;
            defaults to "<name>_image_command_test.yaml".
    """
    main = main or (name + "_main.py")
    dep_group = dep_group or ("crossbuild_" + name)
    image_command_test_config = image_command_test_config or (name + "_image_command_test.yaml")

    py_binary(
        name = name + "_bin",
        srcs = [main],
        dep_group = dep_group,
        main = main,
        python_version = "3.12",
        deps = deps,
    )

    py_image_layer(
        name = "layers",
        binary = ":" + name + "_bin",
    )

    platform_transition_filegroup(
        name = "amd64_layers",
        srcs = [":layers"],
        target_platform = "//:amd64_linux",
    )

    platform_transition_filegroup(
        name = "arm64_layers",
        srcs = [":layers"],
        target_platform = "//:arm64_linux",
    )

    assert_so_arch(
        name = name + "_so_arch_amd64_test",
        actual = ":amd64_layers",
        expected_machine_hex = "3e00",
        so_pattern = so_pattern,
    )

    assert_so_arch(
        name = name + "_so_arch_arm64_test",
        actual = ":arm64_layers",
        expected_machine_hex = "b700",
        so_pattern = so_pattern,
    )

    if check_so_suffix:
        assert_so_suffix(
            name = name + "_so_suffix_amd64_test",
            actual = ":amd64_layers",
            expected_suffix = "cpython-312-x86_64-linux-gnu",
            so_pattern = so_pattern,
        )

        assert_so_suffix(
            name = name + "_so_suffix_arm64_test",
            actual = ":arm64_layers",
            expected_suffix = "cpython-312-aarch64-linux-gnu",
            so_pattern = so_pattern,
        )

    oci_image(
        name = "image",
        base = "@ubuntu",
        entrypoint = ["/app"],
        tars = [":layers"],
    )

    platform_transition_filegroup(
        name = "amd64_image",
        srcs = [":image"],
        target_platform = "//:amd64_linux",
    )

    platform_transition_filegroup(
        name = "arm64_image",
        srcs = [":image"],
        target_platform = "//:arm64_linux",
    )

    container_structure_test(
        name = "amd64_command_test",
        configs = [image_command_test_config],
        image = ":amd64_image",
        platform = "linux/amd64",
        tags = ["requires-docker"],
    )

    container_structure_test(
        name = "arm64_command_test",
        configs = [image_command_test_config],
        image = ":arm64_image",
        platform = "linux/aarch64",
        tags = [
            "requires-docker",
            "requires-qemu",
        ],
    )
