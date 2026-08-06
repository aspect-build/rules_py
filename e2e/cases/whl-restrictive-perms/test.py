"""Below the minimum Bazel this cannot even build: the whl_dist repository rule
aborts at fetch reading a write-only RECORD (#1376).

Every package below archives `dist-info/RECORD` with mode 0o230 (-w--wx---).
Checks the installed layout without executing any of them: their real runtime
deps (torch, mlx, opencv, jax) are deliberately not installed.
"""

import importlib.metadata
import importlib.util

# (distribution, version, importable top-level)
PACKAGES = [
    ("3lc-ultralytics", "0.3.4", "tlc_ultralytics"),
    ("aadt", "1.7.0", "aadt"),
    ("abatcher", "0.2.0", "abatcher"),
    ("abstractvision-mflux", "0.17.5.post1", "mflux"),
    ("acdh-xml-validator", "1.1.0", "acdh_xml_validator"),
    ("augmax", "0.4.1", "augmax"),
]


def main() -> None:
    for distribution, version, top_level in PACKAGES:
        assert importlib.metadata.version(distribution) == version, distribution
        assert importlib.util.find_spec(top_level) is not None, top_level


if __name__ == "__main__":
    main()
    print("OK: installed {} wheels with an unreadable RECORD".format(len(PACKAGES)))
