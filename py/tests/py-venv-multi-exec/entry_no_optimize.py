# `:shared_venv` sets `interpreter_options = ["-O"]`, which only
# affects the venv's own REPL launcher (`bazel run :shared_venv`).
# py_venv_exec consumers don't inherit those flags — they must set
# their own `interpreter_options` to opt in. This consumer leaves
# `interpreter_options` at default; if the venv's `-O` were leaking
# through, `__debug__` would be False here.
#
# NB: must use an explicit `raise`, not `assert`. `-O` strips assert
# statements at compile time, so under the regression we're trying to
# detect, an `assert __debug__` would be removed and the test would
# pass silently.
if not __debug__:
    raise SystemExit(
        "expected __debug__=True — venv-level interpreter_options should "
        "not leak into py_venv_exec consumers",
    )

print("entry_no_optimize ok")
