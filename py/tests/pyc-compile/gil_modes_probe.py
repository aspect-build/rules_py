"""Marshal emits different back-reference flags for this under GIL and free-threaded builds."""


def value() -> set[int]:
    return {i for i in (1, 2, 3)}
