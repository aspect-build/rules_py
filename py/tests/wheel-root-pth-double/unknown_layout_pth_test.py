"""Unknown wheel layouts must still process root .pth files."""

import sys


def main():
    import apkg

    if "rules_py_pth_sentinel_a" not in sys.path:
        raise SystemExit("unknown-layout wheel root .pth did not execute")
    if apkg.VALUE != "apkg":
        raise SystemExit("unknown-layout wheel package did not import")


if __name__ == "__main__":
    main()
