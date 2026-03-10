"""Utilities for processing PEP 735 dependency groups."""

def resolve_dependency_group_specs(dep_groups, group_name):
    """Resolves include-group references in a dependency group.

    PEP 735 allows dependency groups to include other groups via:
        {include-group = "other-group"}

    This function expands these references to their constituent requirement strings,
    preserving the order of specs.

    Args:
        dep_groups: Dict mapping group names to lists of specs.
        group_name: The name of the group to resolve.

    Returns:
        List of resolved requirement strings (no include-group dicts).
    """
    if group_name not in dep_groups:
        fail("Dependency group '{}' not found. Available groups: {}".format(
            group_name,
            ", ".join(sorted(dep_groups.keys())),
        ))

    # Track which groups we've visited to detect cycles.
    # We expand iteratively, one level at a time, until no include-groups remain.
    visited = {group_name: True}

    # Start with the specs from the requested group, tagged with their source for error messages.
    # Each item is either a string (requirement) or a tuple (included_group_name, parent_path).
    pending = []
    for spec in dep_groups[group_name]:
        if type(spec) == "dict":
            if "include-group" not in spec:
                fail("Unknown dict spec in dependency-group '{}': {}".format(group_name, spec))
            pending.append((spec["include-group"], group_name))
        else:
            pending.append(spec)

    # Repeatedly expand include-groups until none remain
    for _ in range(100):  # Max nesting depth
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

                # Expand this include-group inline
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

    # At this point, pending should contain only strings
    return pending
