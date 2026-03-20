"""Verify that the pyproject.toml dependency groups leave build unconstrained."""

import tomllib
from pathlib import Path


def test_build_is_unconstrained():
    pyproject = Path(__file__).parent / "pyproject.toml"
    data = tomllib.loads(pyproject.read_text())

    for group_name, deps in data["dependency-groups"].items():
        for dep in deps:
            if dep.strip().lower().startswith("build"):
                assert dep.strip().lower() == "build", (
                    f"dependency-group {group_name!r} has a constrained build "
                    f"requirement ({dep!r}); this test expects it to be unconstrained"
                )


if __name__ == "__main__":
    test_build_is_unconstrained()
    print("PASSED")
