"""Regression for https://github.com/aspect-build/rules_py/issues/1366.

Both jupyterlab-widgets and widgetsnbextension install data files under the
PEP 427 `.data/data/` scheme into `share/jupyter/...`. Jupyter tools locate
these by walking `<sys.prefix>/share/jupyter` (jupyter_core's data path), the
exact discovery mechanism the issue calls out.

Because both wheels write under the *same* prefix directory `share/jupyter/`,
this also proves the venv merges the two contributions rather than clobbering
one with the other.
"""

import os
import sys

SHARE_JUPYTER = os.path.join(sys.prefix, "share", "jupyter")

# One representative data file from each wheel, keyed by the owning
# distribution, both rooted at the shared `share/jupyter/` prefix.
EXPECTED = {
    "jupyterlab-widgets": os.path.join(
        SHARE_JUPYTER,
        "labextensions",
        "@jupyter-widgets",
        "jupyterlab-manager",
        "package.json",
    ),
    "widgetsnbextension": os.path.join(
        SHARE_JUPYTER,
        "nbextensions",
        "jupyter-js-widgets",
        "extension.js",
    ),
}


def main() -> None:
    print(f"sys.prefix={sys.prefix}")
    missing = []
    for dist, path in EXPECTED.items():
        exists = os.path.isfile(path)
        print(f"{dist}: {path} -> {'found' if exists else 'MISSING'}")
        if not exists:
            missing.append(dist)

    if missing:
        raise SystemExit(
            "FAIL: wheel data files under sys.prefix/share/jupyter are missing "
            f"for {missing}. Wheel `.data/data/share/...` files are installed "
            "into each wheel's tree but never projected into the venv prefix, "
            "so tools that discover resources via sys.prefix/share (jupyter_core, "
            "nbconvert, ...) cannot find them."
        )

    # Both wheels contribute under share/jupyter/; the directory must contain
    # each wheel's subtree, i.e. the venv merged them rather than exposing one.
    entries = set(os.listdir(SHARE_JUPYTER))
    print(f"share/jupyter/ entries: {sorted(entries)}")
    for required in ("labextensions", "nbextensions"):
        if required not in entries:
            raise SystemExit(
                f"FAIL: share/jupyter/{required} is absent — the two wheels "
                "colliding on share/jupyter/ were not merged."
            )

    print("PASS: both wheels' share/jupyter data files are discoverable and merged.")


if __name__ == "__main__":
    main()
