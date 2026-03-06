"""Diffutils constants for patch application.

The system_diffutils repository rule discovers the host `patch` binary and
exports it. Rules that need to apply patches reference it via an implicit
attr label.
"""

# Label for the system patch binary, resolved by system_diffutils repo rule.
PATCH_TOOL_LABEL = "@aspect_rules_py_system_diffutils//:patch"
