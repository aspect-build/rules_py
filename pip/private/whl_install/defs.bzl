def select_chain(name, arms):
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
        )
