"""Our "development" Python dependencies

Users should *not* need to install these. If users see a load()
statement from these, that's a bug in our distribution.

These happen after the regular internal dependencies loads as we need to reference the resolved interpreter
"""

load("@rules_python//python:pip.bzl", "package_annotation", "pip_parse")

PY_WHEEL_RULE_CONTENT = """\
load("@aspect_rules_py//py:defs.bzl", "py_wheel")
py_wheel(
    name = "wheel",
    src = ":whl",
)
"""

def rules_py_internal_pypi_deps(interpreter):
    # Here we can see an example of annotations being applied to an arbitrary
    # package. For details on `package_annotation` and it's uses, see the
    # docs at @rules_python//docs:pip.md`.

    PACKAGES = ["django", "colorama", "django"]
    ANNOTATIONS = {
        pkg: package_annotation(additive_build_content = PY_WHEEL_RULE_CONTENT)
        for pkg in PACKAGES
    }

    pip_parse(
        name = "pypi",
        annotations = ANNOTATIONS,
        python_interpreter_target = interpreter,
        requirements_lock = "//:requirements.txt",
    )
