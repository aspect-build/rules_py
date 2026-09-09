"""Build source-built wheels for several target platforms and assert their tags.

Ported from rules_pycross (tests/e2e/shared/collect_wheels.bzl), which builds
each wheel under a `platform_transition_filegroup` per target platform and
gathers the results into one directory. rules_pycross stops at "it builds";
this version adds a runtime assertion over each wheel's WHEEL `Tag:` metadata
so a wheel tagged for the wrong platform fails the test instead of passing
silently.
It also asserts, for each wheel, that every bundled native .so is an ELF whose
e_machine matches the architecture its `Tag:` claims (see
tools/check_so_arch.py); pure wheels are skipped.
"""

load("@aspect_rules_py//py:defs.bzl", "py_test")
load("@bazel_lib//lib:run_binary.bzl", "run_binary")
load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")

def collect_wheels(name, wheels, platforms, expected_tags, tags = [], check_elf = True):
    """Builds `wheels` once per entry in `platforms` and collects them.

    Args:
        name: Name of the collected-directory target.
        wheels: Wheel labels, e.g. `["@sdist_build__x__y__1_0//:whl"]`.
        platforms: Platform labels to build each wheel for.
        expected_tags: Substrings that must each appear in at least one
            collected wheel's `Tag:` metadata, asserted by `<name>_tags_test`.
        tags: Tags applied to every generated target (e.g. `["manual"]` for a
            collection only a specific host can build).
        check_elf: Also generate `<name>_elf_test`; False for non-ELF targets
            such as macOS wheels.

    The inner `<name>_wheels` filegroup is tagged manual: it is only reachable
    through the platform transitions declared here, which are what supply the
    dep_group and libc flags the wheel targets select on.
    """

    native.filegroup(
        name = name + "_wheels",
        srcs = wheels,
        tags = ["manual"] + [t for t in tags if t != "manual"],
    )

    all_srcs = []
    for platform in platforms:
        transition_name = "_{}_{}".format(name, platform.split(":")[-1])
        platform_transition_filegroup(
            name = transition_name,
            srcs = [name + "_wheels"],
            tags = tags,
            target_platform = platform,
        )
        all_srcs.append(":" + transition_name)

    native.filegroup(
        name = name + "_all_transitions",
        srcs = all_srcs,
        tags = tags,
    )

    run_binary(
        name = name,
        srcs = [name + "_all_transitions"],
        args = [
            "--out-dir",
            "$(@D)",
            "$(execpaths :{}_all_transitions)".format(name),
        ],
        out_dirs = [name],
        tags = tags,
        tool = "//tools:collect_wheels_tool",
    )

    py_test(
        name = name + "_tags_test",
        srcs = ["//tools:check_wheel_tags.py"],
        main = "//tools:check_wheel_tags.py",
        args = ["$(rootpath :{})".format(name)] + expected_tags,
        data = [name],
        tags = tags,
    )

    if not check_elf:
        return

    py_test(
        name = name + "_elf_test",
        srcs = ["//tools:check_so_arch.py"],
        main = "//tools:check_so_arch.py",
        args = ["$(rootpath :{})".format(name)],
        data = [name],
        tags = tags,
    )
