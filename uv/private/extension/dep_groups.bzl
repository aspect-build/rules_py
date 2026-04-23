"""Utilities for resolving PEP 735 dependency groups.

PEP 735 defines dependency groups that can reference other groups via the
`include-group` mechanism. This module provides functions to expand those
references into flat lists of requirement strings while detecting cycles.
"""

def resolve_dependency_group_specs(dep_groups, group_name):
    """Resolves `include-group` references within a PEP 735 dependency group.

    Expands nested group references iteratively until only requirement strings
    remain. Detects circular references and unknown group names, failing with
    a descriptive message.

    Args:
        dep_groups: A dictionary mapping group names to lists of specs. Each
            spec is either a requirement string or a dict with an
            `include-group` key.
        group_name: The name of the group to resolve.

    Returns:
        A list of resolved requirement strings with all `include-group` dicts
        expanded and removed.
    """
    if group_name not in dep_groups:
        fail("Dependency group '{}' not found. Available groups: {}".format(
            group_name,
            ", ".join(sorted(dep_groups.keys())),
        ))

    visited = {group_name: True}

    pending = []
    for spec in dep_groups[group_name]:
        if type(spec) == "dict":
            if "include-group" not in spec:
                fail("Unknown dict spec in dependency-group '{}': {}".format(group_name, spec))
            pending.append((spec["include-group"], group_name))
        else:
            pending.append(spec)

    for _ in range(100):
        has_includes = False
        next_pending = []

        for item in pending:
            if type(item) == "tuple":
                has_includes = True
                included_group, parent = item

                if included_group in visited:
                    fail("Circular dependency-group reference detected: '{}' includes '{}' which was already visited".format(
                        parent,
                        included_group,
                    ))

                if included_group not in dep_groups:
                    fail("Dependency group '{}' not found (included from '{}'). Available groups: {}".format(
                        included_group,
                        parent,
                        ", ".join(sorted(dep_groups.keys())),
                    ))

                visited[included_group] = True

                for spec in dep_groups[included_group]:
                    if type(spec) == "dict":
                        if "include-group" not in spec:
                            fail("Unknown dict spec in dependency-group '{}': {}".format(included_group, spec))
                        next_pending.append((spec["include-group"], included_group))
                    else:
                        next_pending.append(spec)
            else:
                next_pending.append(item)

        pending = next_pending

        if not has_includes:
            break

    return pending
