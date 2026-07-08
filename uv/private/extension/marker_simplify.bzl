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
