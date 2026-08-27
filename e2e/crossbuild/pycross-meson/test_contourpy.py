#!/usr/bin/env python3
import math

import numpy as np
import contourpy


def main() -> None:
    x = np.array([0.0, 1.0, 2.0])
    y = np.array([0.0, 1.0, 2.0])
    z = np.array([[0.0, 1.0, 2.0], [1.0, 2.0, 3.0], [2.0, 3.0, 4.0]])
    cg = contourpy.contour_generator(x, y, z)
    lines = cg.lines(1.5)
    assert len(lines) == 1, "expected exactly one contour line, got {}".format(len(lines))

    # z=x+y is bilinear (no cross term), so its 1.5-contour is the exact
    # line x+y=1.5 from (0,1.5) to (1.5,0) — hand-verified, not just captured
    # output.
    expected = [(0.0, 1.5), (0.5, 1.0), (1.0, 0.5), (1.5, 0.0)]
    points = [tuple(p) for p in lines[0]]
    assert len(points) == len(expected), "expected {} points, got {}".format(len(expected), len(points))
    for got, want in zip(points, expected):
        assert math.isclose(got[0], want[0], abs_tol=1e-9) and math.isclose(got[1], want[1], abs_tol=1e-9), \
            "point {} != expected {}".format(got, want)

    print("OK")


if __name__ == "__main__":
    main()
