"""
Helpers.
"""

def select_chain(name, arms, visibility = ["//visibility:private"]):
    """
    Generate an ordered select chain.

    Creates a stack of one-at-a-time `select()`s such that each condition ->
    target mapping in the arms list will be _sequentially_ evaluated. This
    allows callers to express _preference_ among configuration possibilities by
    explicitly imposing a selection _ordering_.

    Args:
        name (str): The name for the select chain rule.
        arms (list): Ordered selection cases as (condition, target) pairs.

    Returns:
        Nothing.
    """

    for index, kv in enumerate(arms.items()):
        condition, target = kv
        next = "{}_{}".format(name, index + 1) if index + 1 < len(arms) else None
        native.alias(
            name = "{}{}".format(name, "_{}".format(index) if index > 0 else ""),
            actual = select(
                # Npte that default comes first so that if the user defines a default, theirs wins.
                ({"//conditions:default": next} if next else {}) | {
                    condition: target,
                },
            ),
            visibility = visibility,
        )
