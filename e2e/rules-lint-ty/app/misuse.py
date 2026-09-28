from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from shapes.geometry import Point


def norm(point: "Point") -> float:
    return (point.x**2 + point.y**2) ** 0.5


norm(3)
