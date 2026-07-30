"""Four unknown-layout wheels, four `site.addsitedir` lines, one prologue.

The companion snapshot (`snapshots/multi_addsitedir.venv.pth`) pins the file
shape; this pins that the shape still works — every wheel on sys.path exactly
once, sharing one `known_paths` set across all four lines.
"""

import sys

PACKAGES = ("iniconfig", "packaging", "pluggy", "pygments")


def main() -> None:
    site_packages = [p for p in sys.path if p.endswith("site-packages")]
    if len(site_packages) != len(set(site_packages)):
        duplicates = sorted({p for p in site_packages if site_packages.count(p) > 1})
        raise SystemExit("duplicate site-packages on sys.path: {}".format(duplicates))

    for pkg in PACKAGES:
        owned = [p for p in site_packages if "/{}_no_top_levels/".format(pkg) in p]
        if len(owned) != 1:
            raise SystemExit(
                "expected exactly one sys.path entry for {}, got {}".format(pkg, owned)
            )
        __import__(pkg)


if __name__ == "__main__":
    main()
