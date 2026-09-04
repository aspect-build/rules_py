#!/usr/bin/env python3
"""Exercises the cross-compiled rpds extension."""
import rpds


def main() -> None:
    # push_front(0) onto [1, 2, 3] must yield 0, 1, 2, 3 in iteration order.
    values = list(rpds.List([1, 2, 3]).push_front(0))
    assert values == [0, 1, 2, 3], "expected [0, 1, 2, 3], got {}".format(values)
    print("OK")


if __name__ == "__main__":
    main()
