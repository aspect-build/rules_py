"""Asserts a rules_py binary's venv sources and imports reached this target.

Run by an @rules_python py_test that depends on the rules_py binary: the
launcher rule must surface the sibling venv's imports and transitive
sources (the binary's own srcs and its deps) through rules_python's PyInfo.
"""

import tool

assert tool.TOOL_NAME == "rules_py tool", tool.TOOL_NAME
assert tool.GREETING == "hello from rules_py", tool.GREETING
