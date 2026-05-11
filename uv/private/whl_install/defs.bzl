"""
Helpers.
"""

def select_chain(name, arms, default_target = None, visibility = ["//visibility:private"]):
    """
    Generate an ordered select chain.

    Creates a stack of one-at-a-time `select()`s such that each condition ->
    target mapping in the arms list will be _sequentially_ evaluated. This
    allows callers to express _preference_ among configuration possibilities by
    explicitly imposing a selection _ordering_.

    Args:
        name (str): The name for the select chain rule.
        arms (list): Ordered selection cases as (condition, target) pairs.
        default_target (str | None): Optional default target for unmatched configs.
        visibility (list): Visibility spec for the generated conditions.

    Returns:
        Nothing.
    """

    # Empty arms (e.g. sdist-only packages): the loop would emit zero aliases
    # and leave `:name` undefined for downstream consumers.
    if not arms:
        if default_target:
            native.alias(
                name = name,
                actual = default_target,
                visibility = visibility,
            )
        return

    for index, kv in enumerate(arms.items()):
        condition, target = kv
        next = "{}_{}".format(name, index + 1) if index + 1 < len(arms) else default_target
        native.alias(
            name = "{}{}".format(name, "_{}".format(index) if index > 0 else ""),
            actual = select(
                # Note that default comes first so that if the user defines a default, theirs wins.
                ({"//conditions:default": next} if next else {}) | {
                    condition: target,
                },
            ),
            visibility = visibility,
        )
