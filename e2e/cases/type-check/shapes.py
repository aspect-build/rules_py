from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from stubs_only import Sized


def area(width: int, height: int) -> int:
    return width * height


def describe(item: "Sized") -> str:
    return f"{item.size} units"
