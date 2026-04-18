"""Diffutils constants for patch application.

The system_diffutils repository rule discovers the host `patch` binary and
exports it. Rules that need to apply patches reference it via an implicit
attr label.
"""

PATCH_TOOL_LABEL = "@aspect_rules_py_system_diffutils//:patch"
