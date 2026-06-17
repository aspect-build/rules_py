# Workspace dependencies; #789

The `foo` and `pi` workspace members contain installable code, so their
`uv.override_package()` annotations map them to Bazel targets. The generated
dependency graph must preserve dependencies between those targets and packages
from the uv hub.

The `dependency-bag` member has `package = false`, so uv records it as virtual.
It contributes `humanize` to the dependency graph without requiring an override
target of its own.
