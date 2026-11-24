"""Partial evaluation of PEP 508 `extra` markers during graph construction.

uv writes every dependency of an extra with a redundant `extra == '<name>'`
marker. An edge out of an extra pseudo-package is only ever traversed once that
extra is active, so once we know which extra an edge belongs to that clause is a
known boolean. We resolve it here rather than emitting an un-evaluable
`decide_marker`, which would later see an empty `extra` environment (the venv
name is not the extra) and wrongly drop the dependency.
"""

load("//uv/private/markers:pep508_evaluate.bzl", "evaluate", "tokenize")

def simplify_extra_marker(marker, extra):
    """Partially evaluate a marker binding the `extra` PEP 508 variable.

    Args:
        marker: The PEP 508 marker string on the edge.
        extra: The name of the active extra the edge belongs to.

    Returns:
        - `""` if the marker reduces to true.
        - `None` if it reduces to false (the clause names a different extra).
        - The residual marker string when other (e.g. platform) clauses remain.
    """
    if not marker:
        return marker
    res = evaluate(marker, env = {"extra": extra}, strict = False)
    if res == False:
        return None
    if res == True:
        return ""
    return res

def _uv_normalize(name):
    """Normalizes a package or group name the way uv does (PEP 503).

    Lowercases the name and collapses every run of `-`, `_` and `.` into a
    single `-`.
    """
    out = []
    for char in name.lower().elems():
        if char in "-_.":
            if out and out[-1] != "-":
                out.append("-")
        else:
            out.append(char)
    return "".join(out).strip("-")

def conflict_group_extra(project_name, group_name):
    """Returns the `extra` value uv's lock uses to mark a dependency group active.

    When a project declares `[tool.uv] conflicts`, `uv lock` routes every
    conflicting fork with markers over synthetic extras named
    `group-<len>-<project>-<group>`, where `<project>` is the normalized name
    of the project declaring the group and `<len>` is its length.

    Args:
        project_name: The name of the project that declares the group.
        group_name: The dependency group's name.

    Returns:
        The conflict-routing extra for the group.
    """
    project = _uv_normalize(project_name)
    return "group-{}-{}-{}".format(len(project), project, _uv_normalize(group_name))

def conflict_group_extras(project_data, lock_data):
    """Describes, for each dependency group, how uv routes it through conflicts.

    Args:
        project_data: The parsed `pyproject.toml`.
        lock_data: The parsed `uv.lock`.

    Returns:
        `{group_name: struct(extra, labels)}`, where `extra` is the group's own
        conflict-routing extra and `labels` is every routing extra the lockfile
        can name (one per item of its `conflicts` table). Empty when the
        lockfile declares no conflicts, since uv then writes no routing
        markers.
    """
    project_name = project_data.get("project", {}).get("name")
    conflicts = lock_data.get("conflicts", [])
    if not conflicts or not project_name:
        return {}

    labels = {}
    for conflict_set in conflicts:
        for item in conflict_set:
            if "group" in item:
                labels[conflict_group_extra(item["package"], item["group"])] = 1
            elif "extra" in item:
                package = _uv_normalize(item["package"])
                labels["extra-{}-{}-{}".format(len(package), package, _uv_normalize(item["extra"]))] = 1

    return {
        group_name: struct(
            extra = conflict_group_extra(project_name, group_name),
            labels = labels,
        )
        for group_name in project_data.get("dependency-groups", {}).keys()
    }

def _names_only_conflict_labels(marker, labels):
    """Returns True if every `extra` term in a marker names a conflict label."""
    tokens = tokenize(marker)
    found = False
    for i in range(len(tokens)):
        if tokens[i] != "extra":
            continue
        if i + 2 < len(tokens) and tokens[i + 1] in ("==", "!="):
            value = tokens[i + 2]
        elif i >= 2 and tokens[i - 1] in ("==", "!="):
            value = tokens[i - 2]
        else:
            return False
        if not value.startswith('"') or value.strip('"') not in labels:
            return False
        found = True
    return found

def simplify_conflict_markers(markers, conflict):
    """Decides uv's conflict-routing markers for one dependency group.

    A configuration built for a dependency group is exactly "this group is
    active and no other conflict item is". Binding `extra` to the group's own
    routing label therefore gives every routing term uv's meaning:
    `extra == L` holds only for the group's label, `extra != L` for every
    other label, and a conjunction of two labels (uv's "both active" fork)
    never holds. Environment terms are left for `decide_marker`.

    Only markers whose `extra` terms all name routing labels are decided; a
    marker that also names a package extra is returned unchanged, so the
    extra-aware simplification downstream still sees it.

    Args:
        markers: A dictionary mapping marker strings to 1.
        conflict: The group's entry from `conflict_group_extras`, or None when
            the lockfile has no conflicts (the markers are returned
            unchanged).

    Returns:
        A dictionary of simplified markers; empty when every marker is false
        for the group, and `{"": 1}` when one of them always holds.
    """
    if conflict == None:
        return markers

    acc = {}
    for marker in markers.keys():
        if not marker or "extra" not in marker or not _names_only_conflict_labels(marker, conflict.labels):
            acc[marker] = 1
            continue
        simplified = simplify_extra_marker(marker, conflict.extra)
        if simplified != None:
            acc[simplified] = 1
    return acc
