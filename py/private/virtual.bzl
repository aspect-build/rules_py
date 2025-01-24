"""Utility functions around managing virtual dependencies and resoloutions"""

_RESOLUTION_SENTINEL_KEY = "_RESOLUTION_SENTINEL"

def _make_resolutions(base, requirement_fn = lambda r: r):
    """Returns data representing the resolution for a given set of dependencies

    Args:
        base: Base set of requirements to turn into resolutions.
        requirement_fn: Optional function to transform the Python package name into a requirement label.

    Returns:
        A resolution struct for use with virtual deps.
    """

    if not _RESOLUTION_SENTINEL_KEY in base:
        _resolutions = dict([
            [
                k,
                _make_resolution(
                    name = k,
                    requirement = requirement_fn(k),
                ),
            ]
            for k in base.keys()
        ], **{_RESOLUTION_SENTINEL_KEY: True})
    else:
        _resolutions = base

    return struct(
        resolutions = _resolutions,
        override = lambda overrides, **kwargs: _make_resolutions(_make_overrides(_resolutions, overrides)),
        to_label_keyed_dict = lambda: dict({v.requirement: v.name for k, v in _resolutions.items() if k != _RESOLUTION_SENTINEL_KEY}),
    )

def _make_overrides(resolutions, overrides):
    _overrides = dict([
        [
            k,
            _make_resolution(
                name = k,
                requirement = v,
            ),
        ]
        for k, v in overrides.items()
    ])

    return dict(resolutions, **_overrides)

def _make_resolution(name, requirement):
    """Creates a Python virtual dependency resolution from the libraries name and requirement.

    Args:
        name: Name of the dependency to include
        requirement: The requirement label to use for the dependency
    """

    return struct(
        name = name,
        requirement = requirement,
    )

def _from_requirements(base, requirement_fn = lambda r: r):
    if type(base) == "list":
        base = {k: None for k in base}
    return _make_resolutions(base, requirement_fn)

resolutions = struct(
    from_requirements = _from_requirements,
    empty = lambda: _make_resolutions({}),
)
