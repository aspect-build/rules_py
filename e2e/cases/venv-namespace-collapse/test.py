"""Namespace entries collapse to the directories a single wheel owns.

`nvidia-cuda-cccl` and `nvidia-cuda-runtime` are pure data wheels sharing the
PEP 420 namespace `nvidia`: no `__init__.py` anywhere, so every one of their
2118 installed files resolves to its own namespace entry. Projecting those per
file costs a declared output and a symlink action per file in every consuming
venv.

This test runs inside such a venv, so its own site-packages is the projection.
It asserts the shape (directories the wheels share stay real, subtrees a single
wheel owns bind as one symlink) and the consequence (headers still resolve
through the bound directories, which is what a consumer passing
`-I<site-packages>/nvidia/cu13/include` to nvcc depends on).
"""

import os
import sys

# Both wheels contribute to `nvidia` with no `__init__.py`, so importing it at
# all exercises the PEP 420 union across the two install trees.
import nvidia

NS = nvidia.__path__[0]
INCLUDE = os.path.join(NS, "cu13", "include")

# Shared by both wheels, so assembly must descend through them: they stay real
# directories the venv owns.
SHARED = ("cu13", "cu13/include")

# Owned outright by one wheel: bound whole, one symlink each.
OWNED = (
    "cu13/cccl",
    "cu13/include/cccl",
    "cu13/include/nv",
    "cu13/include/cooperative_groups",
    "cu13/lib",
)

# One header per bound directory, plus a loose one that has no directory to
# collapse into (it sits directly in the shared `include/`).
HEADERS = (
    "cu13/include/cccl/cub/cub.cuh",
    "cu13/include/nv/target",
    "cu13/include/cooperative_groups/reduce.h",
    "cu13/include/cuda_runtime.h",
)

# Uncollapsed this is 2108. The bound directories account for all but the ~77
# loose headers `nvidia-cuda-runtime` installs into the shared `include/`.
MAX_LINKS = 200


def symlinks_under(root: str) -> list:
    """Every symlink in the tree, not following any of them."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                found.append(os.path.relpath(path, root))
        # os.walk still recurses into symlinked directories unless pruned; the
        # projection ends at each one, and beyond it lies the wheel's install
        # tree, whose files are not this venv's outputs.
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))]
    return found


def main() -> None:
    print("nvidia.__path__={}".format(nvidia.__path__))

    failures = []

    for relative in SHARED:
        path = os.path.join(NS, relative)
        if os.path.islink(path) or not os.path.isdir(path):
            failures.append(
                "{} should be a real directory: both wheels ship below it, so "
                "assembly has to descend through it".format(relative)
            )

    for relative in OWNED:
        path = os.path.join(NS, relative)
        if not os.path.islink(path):
            failures.append(
                "{} should be a directory symlink: one wheel owns everything "
                "below it, so it binds whole".format(relative)
            )

    for relative in HEADERS:
        path = os.path.join(NS, relative)
        if not os.path.isfile(path):
            failures.append("{} does not resolve through the projection".format(relative))

    links = symlinks_under(NS)
    if len(links) > MAX_LINKS:
        failures.append(
            "{} symlinks under site-packages/nvidia, expected at most {}. The "
            "per-wheel subtrees are being projected file by file instead of "
            "binding at the directory that owns them.".format(len(links), MAX_LINKS)
        )

    if failures:
        print("FAIL:")
        for failure in failures:
            print("  {}".format(failure))
        sys.exit(1)

    print("{} symlinks under site-packages/nvidia".format(len(links)))
    print("PASS: namespace entries collapsed to single-owner directories.")


if __name__ == "__main__":
    main()
