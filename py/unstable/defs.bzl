"""Removed in rules_py v2.0.0.

- `py_venv` and `py_venv_link` graduated to
  `@aspect_rules_py//py:defs.bzl`.
- `py_venv_binary` and `py_venv_test` were removed entirely. Use
  `py_binary` / `py_test` from `@aspect_rules_py//py:defs.bzl` with
  `expose_venv = True, isolated = False` for the equivalent shape — a
  sibling `:<name>.venv` py_venv plus a PYTHONPATH-honoring launcher.
"""

def _removed(name):
    def _fail(*args, **kwargs):
        fail(
            "rules_py v2.0.0: @aspect_rules_py//py/unstable:defs.bzl has been " +
            "removed.\n" +
            "  * py_venv / py_venv_link: load from @aspect_rules_py//py:defs.bzl.\n" +
            "  * py_venv_binary / py_venv_test: removed. Use py_binary / py_test " +
            "from @aspect_rules_py//py:defs.bzl with " +
            "`expose_venv = True, isolated = False` for equivalent behaviour.",
        )

    return _fail

py_venv = _removed("py_venv")
py_venv_link = _removed("py_venv_link")
py_venv_binary = _removed("py_venv_binary")
py_venv_test = _removed("py_venv_test")
