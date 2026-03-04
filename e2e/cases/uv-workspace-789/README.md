# Editable internal dependencies; #789

UV workspaces allow for packages within the workspace to depend on each other.
The UV extension needs to force the user to provide an override target mapping
for each such target, and dependencies BETWEEN these projects' Bazel targets
need to work. Dependencies taken via the UV hub need to work as well.
