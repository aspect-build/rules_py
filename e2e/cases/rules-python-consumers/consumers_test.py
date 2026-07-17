"""Asserts rules_python's toolchain consumers work against rules_py-provisioned
toolchains, which they reach only via toolchain types — never via labels inside
the generated interpreter repos.
"""

import os


def read(rel):
    path = os.path.join(
        os.environ["TEST_SRCDIR"],
        os.environ["TEST_WORKSPACE"],
        "rules-python-consumers",
        rel,
    )
    with open(path) as f:
        return f.read().strip()


# rules_python's current_py_toolchain expanded $(PYTHON3) from the resolved
# standard toolchain — backed by rules_py's provisioned 3.13 runtime.
python3 = read("python3_var.txt")
assert "python_interpreters+python_3_13" in python3, python3

# The exec-tools payload serves an exec runtime from a rules_py-provisioned repo.
facts = read("exec_tools_facts.txt").splitlines()
assert "python_interpreters+" in facts[0], facts

assert read("python_launcher.txt") == "3.11"

wheel_root = os.path.join(
    os.environ["TEST_SRCDIR"],
    os.environ["TEST_WORKSPACE"],
    "rules-python-consumers",
    "compat_wheel_files",
)
assert any(
    name.endswith("consumers_test.py")
    for _, _, files in os.walk(wheel_root)
    for name in files
), wheel_root

print("OK")
