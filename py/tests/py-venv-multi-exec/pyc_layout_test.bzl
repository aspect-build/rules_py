"""Runs pyc_layout_check.py over a launcher's shipped runfiles."""

load("//py:defs.bzl", "py_test")

def pyc_layout_test(name, target, mode, module = "entry_a", pyc_tag = "", protect_source = False, expect_sourceless = True, expect_pyc = True, check_mappings = False, expect_suffixes = []):
    args = ["--mode", mode, "--module", module]
    if pyc_tag:
        args += ["--pyc-tag", pyc_tag]
    if protect_source:
        args.append("--protect-source")
    if not expect_sourceless:
        args.append("--no-sourceless")
    if not expect_pyc:
        args.append("--no-pycache")
    if check_mappings:
        args.append("--check-mappings")
    for suffix in expect_suffixes:
        args += ["--expect-suffix", suffix]
    py_test(
        name = name,
        srcs = [Label(":pyc_layout_check.py")],
        main = Label(":pyc_layout_check.py"),
        args = args,
        data = [target],
    )
