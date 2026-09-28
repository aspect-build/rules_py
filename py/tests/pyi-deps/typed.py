from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import cowsay  # noqa: F401 - a wheel pyi_dep, imported only for type checking
    from heavy import Heavy


def weigh(item: "Heavy") -> int:
    return item.weight
