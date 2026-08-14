"""Structural checks on a native extension .so inside a py_image_layer tar.

Both check the *squashed* tar specifically — the "default" one is the
runfiles/source layer and never contains the installed pip package, only
"squashed" does. Neither proves the code runs correctly; pair with an
execution test (e.g. container_structure_test) for that.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")

def _squashed_tar_check(name, actual, script, so_pattern, expected):
    check_name = "_{}_check".format(name)
    native.genrule(
        name = check_name,
        srcs = [actual],
        outs = ["{}.ok".format(check_name)],
        cmd = """
tar_file=$$(echo $(SRCS) | tr ' ' '\\n' | grep '_squashed\\.tar' | head -1)
$(location {script}) $$tar_file '{so_pattern}' '{expected}'
touch $@
""".format(script = script, so_pattern = so_pattern, expected = expected),
        tools = [script],
    )
    build_test(
        name = name,
        targets = [":{}".format(check_name)],
    )

def assert_so_arch(name, actual, so_pattern, expected_machine_hex):
    """Checks the ELF e_machine of a native extension .so inside a py_image_layer tar.

    Args:
        name: test name.
        actual: the py_image_layer (or a platform_transition_filegroup wrapping one) to check.
        so_pattern: grep -E pattern matching the .so's full path inside the tar.
        expected_machine_hex: little-endian ELF e_machine hex, e.g. "3e00" (x86_64), "b700" (aarch64).
    """
    _squashed_tar_check(name, actual, "//tools:check_so_arch.sh", so_pattern, expected_machine_hex)

def assert_so_suffix(name, actual, so_pattern, expected_suffix):
    """Checks the EXT_SUFFIX/SOABI in a native extension .so's filename inside a py_image_layer tar.

    Args:
        name: test name.
        actual: the py_image_layer (or a platform_transition_filegroup wrapping one) to check.
        so_pattern: grep -E pattern matching the .so's full path inside the tar.
        expected_suffix: substring expected in the matched filename, e.g. "cpython-312-x86_64-linux-gnu".
    """
    _squashed_tar_check(name, actual, "//tools:check_so_suffix.sh", so_pattern, expected_suffix)
