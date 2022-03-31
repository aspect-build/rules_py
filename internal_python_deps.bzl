"""Our "development" Python dependencies

Users should *not* need to install these. If users see a load()
statement from these, that's a bug in our distribution.

These happen after the regular internal dependencies loads as we need to reference the resolved interpreter
"""

load("@rules_python//python:pip.bzl", "pip_parse")

def rules_py_internal_pypi_deps(interpreter):
    pip_parse(
        name = "pypi",
        python_interpreter_target = interpreter,
        requirements_lock = "//py/tests/external-deps:requirements.txt",
    )
