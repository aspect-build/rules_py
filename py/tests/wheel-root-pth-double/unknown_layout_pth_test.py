"""Unknown wheel layouts must still process root .pth files."""

import os
import sys


def statically_visible_dirs() -> list[str]:
    """Directories a static analyzer (pyright, ty) takes from the venv `.pth`.

    Such tools skip `import` lines and resolve the remaining lines against
    the `.pth` file's directory without executing anything.
    """
    for root, _dirs, files in os.walk(sys.prefix):
        for name in sorted(files):
            if not name.endswith(".pth"):
                continue
            path = os.path.join(root, name)
            with open(path) as fh:
                lines = fh.read().splitlines()
            if not any("site.addsitedir(" in ln for ln in lines):
                continue
            return [
                os.path.normpath(os.path.join(root, ln.strip()))
                for ln in lines
                if ln.strip() and not ln.startswith(("import ", "import\t", "#"))
            ]
    raise SystemExit("no venv .pth calling site.addsitedir under {}".format(sys.prefix))


def main() -> None:
    if "rules_py_pth_sentinel_a" not in sys.path:
        raise SystemExit("unknown-layout wheel root .pth did not execute")

    import apkg

    if apkg.VALUE != "apkg":
        raise SystemExit("unknown-layout wheel package did not import")

    if not any(
        os.path.isdir(os.path.join(d, "apkg")) for d in statically_visible_dirs()
    ):
        raise SystemExit(
            "unknown-layout wheel is reachable only through an `import` line "
            "of the venv .pth, which static analyzers do not execute"
        )


if __name__ == "__main__":
    main()
