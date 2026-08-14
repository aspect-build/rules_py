"""Shared scaffolding for a "build one real package for amd64+arm64" case.

Every case cross-compiles a package for linux/amd64 and linux/arm64 and
asserts structure in-suite (ELF machine, and, where the .so's filename
carries one, its cpython ABI tag). Execution is deliberately NOT part of
`bazel test //...`: the docker-loadable tarballs declared here are built by
CI's crossbuild-verify pipelines, uploaded, and run on NATIVE hardware per
target arch — no same-host docker+QEMU sandwich. This macro is the lines
every case shared verbatim; anything genuinely case-specific stays
hand-written — see //geohash and //zstandard.
"""

load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer")
load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")
load(":checks.bzl", "assert_so_arch", "assert_so_suffix")

def pep517_cross_case(name, deps, so_pattern, check_so_suffix = True, main = None, dep_group = None):
    """Declares the amd64/arm64 build+run scaffolding for one e2e/crossbuild package.

    Produces (all unprefixed, matching the package's own BUILD.bazel):
    "<name>_bin", "layers", "{amd64,arm64}_layers", "<name>_so_arch_{amd64,arm64}_test",
    "<name>_so_suffix_{amd64,arm64}_test" (if check_so_suffix), "image",
    "{amd64,arm64}_image", "{amd64,arm64}_load", "{amd64,arm64}_tarball".

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
    """
    main = main or (name + "_main.py")
    dep_group = dep_group or ("crossbuild_" + name)

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

    # Docker-loadable tarballs consumed by CI's crossbuild-verify pipelines:
    # a builder job `bazel build`s these, uploads them, and native
    # amd64/arm64 runner jobs `docker load` + `docker run` them on real
    # hardware. This is the ONLY execution verification for these cases.
    # Tagged manual: repackaging is dead weight under plain `//...`. The
    # repo_tag is what the runner executes: `crossbuild/<name>:<arch>`.
    for arch in ("amd64", "arm64"):
        oci_load(
            name = arch + "_load",
            image = ":" + arch + "_image",
            repo_tags = ["crossbuild/" + name + ":" + arch],
            tags = ["manual"],
        )

        native.filegroup(
            name = arch + "_tarball",
            srcs = [":" + arch + "_load"],
            output_group = "tarball",
            tags = ["manual"],
        )
