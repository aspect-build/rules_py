"""Helpers for partially evaluating PEP 508 markers.

These are used during graph construction to resolve `extra == '...'` markers
once we already know which extras are being activated. Resolving them early
means `decide_marker` does not need to know about extras at build time.
"""

load("//uv/private/markers:pep508_evaluate.bzl", "evaluate", "tokenize")

def simplify_extra_marker(marker, extras):
    """Partially evaluate a marker binding the `extra` PEP 508 variable.

    Once we know which extras of a package are activated for a configuration,
    any `extra == '...'` sub-expression in the optional-dependency markers of
    those extras becomes a known boolean. This prevents `decide_marker` from
    later evaluating `extra` markers based only on the venv name heuristic.

    Args:
        marker: The PEP 508 marker string to simplify.
        extras: A list of extra names that are active for the package.

    Returns:
        - `""` if the marker simplifies to true.
        - `None` if the marker simplifies to false.
        - A residual marker string if parts of it cannot be evaluated (e.g.
          because they also depend on platform markers).
    """
    if not marker or "extra" not in marker:
        return marker

    residuals = []
    seen_true = False
    for extra in extras:
        result = evaluate(marker, env = {"extra": extra}, strict = False)
        if type(result) == type(True):
            if result:
                seen_true = True
                break
            continue
        if type(result) == type(""):
            if not result:
                # The evaluator returns an empty string when the expression
                # reduced to true but other terms were unresolved.
                seen_true = True
                break
            if result not in residuals:
                residuals.append(result)
        else:
            fail("Unexpected marker evaluation result for {}: {}".format(marker, result))

    if seen_true:
        return ""
    if not residuals:
        return None
    if len(residuals) == 1:
        return residuals[0]
    return "({})".format(") or (".join(residuals))

def simplify_markers_for_extras(markers, extras):
    """Simplify a collection of markers given a set of active extras.

    Args:
        markers: A dictionary mapping marker strings to 1.
        extras: A list of active extra names.

    Returns:
        A dictionary of simplified markers, or an empty dictionary if all
        markers simplified to false.
    """
    acc = {}
    for marker in markers.keys():
        simplified = simplify_extra_marker(marker, extras)
        if simplified != None:
            acc[simplified] = 1
    return acc

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
    of the project declaring the group and `<len>` is its length. A dependency
    group's configuration is exactly "this group is active and no other
    conflict item is", so those markers can be decided once the group is
    known.

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
        simplified = simplify_extra_marker(marker, [conflict.extra])
        if simplified != None:
            acc[simplified] = 1
    return acc

# Tokens that are allowed in an "extra-only" marker.
_EXTRA_ONLY_TOKENS = {
    "extra": True,
    "==": True,
    "!=": True,
    "<": True,
    ">": True,
    "<=": True,
    ">=": True,
    "~=": True,
    "===": True,
    "in": True,
    "not in": True,
    "and": True,
    "or": True,
    "not": True,
    "(": True,
    ")": True,
}

def is_extra_only_marker(marker):
    """Return True if a marker only references the `extra` variable.

    uv uses `extra == '...'` markers both for real package extras and for
    internal conflict-routing labels. These markers cannot be evaluated at
    Bazel build time because `extra` is not part of the execution environment.
    Detecting them lets the BUILD generator treat them as already resolved by
    the active dependency group.

    Args:
        marker: The PEP 508 marker string to inspect.

    Returns:
        True if the marker only depends on `extra`, False otherwise.
    """
    if not marker or "extra" not in marker:
        return False

    for token in tokenize(marker):
        if token in _EXTRA_ONLY_TOKENS:
            continue
        if token.startswith('"'):
            # Quoted string literal.
            continue

        # Any other token is an environment variable or unknown operator.
        return False

    return True
