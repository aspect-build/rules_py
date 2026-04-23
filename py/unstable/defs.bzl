"""Removed in rules_py v2.0.0.

- `py_venv` and `py_venv_link` graduated to
  `@aspect_rules_py//py:defs.bzl`.
- `py_venv_binary` and `py_venv_test` were removed entirely. Use
  `py_binary` / `py_test` with `expose_venv = True, isolated = False`
  for the equivalent shape — a sibling `:<name>.venv` py_venv plus a
  PYTHONPATH-honoring launcher.
"""

fail(
    "rules_py v2.0.0: @aspect_rules_py//py/unstable:defs.bzl has been " +
    "removed.\n" +
    "  * py_venv / py_venv_link: load from @aspect_rules_py//py:defs.bzl.\n" +
    "  * py_venv_binary / py_venv_test: removed. Use py_binary / py_test " +
    "from @aspect_rules_py//py:defs.bzl with " +
    "`expose_venv = True, isolated = False` for equivalent behaviour " +
    "(emits a sibling `:<name>.venv` py_venv + a rule consuming it via " +
    "external_venv, with a PYTHONPATH-honoring launcher). Most callers " +
    "can drop those two attrs and just use plain py_binary / py_test — " +
    "analysis-time venv assembly is the default.",
)
