#!/usr/bin/env python3
"""
Console script entry point generator for aspect_rules_py.

This is a simplified version of rules_python's generator that works
with our UV-based package management system.
"""

import argparse
import configparser
import os
import pathlib

_TEMPLATE = '''\
import sys
import os

if getattr(sys.flags, "safe_path", False):
    pass
elif ".runfiles" not in sys.path[0]:
    sys.path = sys.path[1:]

# Add dist-info directory to sys.path for importlib_metadata support
_DIST_INFO_DIR = "{dist_info_dir}"
if _DIST_INFO_DIR:
    # Search for the dist-info directory in runfiles and add its parent to sys.path
    # The parent directory (which contains both the package and dist-info) must be
    # in sys.path for importlib_metadata to find the metadata
    for path in sys.path[:]:
        potential = os.path.join(path, _DIST_INFO_DIR)
        if os.path.isdir(potential):
            # Found it - the path that contains the dist-info is already in sys.path
            break
        # Also check if we're at the package level and need to go up
        parent = os.path.dirname(path)
        potential_in_parent = os.path.join(parent, _DIST_INFO_DIR)
        if os.path.isdir(potential_in_parent):
            if parent not in sys.path:
                sys.path.insert(0, parent)
            break

try:
    from {module} import {attr}
except ImportError:
    entries = "\\n".join(sys.path)
    print("Printing sys.path entries for easier debugging:", file=sys.stderr)
    print(f"sys.path is:\\n{{entries}}", file=sys.stderr)
    raise

if __name__ == "__main__":
    sys.exit({entry_point}())
'''


class EntryPointsParser(configparser.ConfigParser):
    """Parser for entry_points.txt files."""
    optionxform = staticmethod(str)


def parse_entry_points(entry_points_txt: pathlib.Path) -> dict[str, str]:
    """Parse entry_points.txt and return console_scripts mapping."""
    config = EntryPointsParser()
    config.read(entry_points_txt)
    
    if "console_scripts" not in config.sections():
        return {}
    
    return dict(config["console_scripts"])


def find_entry_points_and_dist_info(path: pathlib.Path) -> tuple[pathlib.Path, str]:
    """Find entry_points.txt and the dist-info directory under a path."""
    entry_points = None
    dist_info_dir = ""
    if path.is_dir():
        for root, dirs, files in os.walk(path):
            if entry_points is None and "entry_points.txt" in files:
                entry_points = pathlib.Path(root) / "entry_points.txt"
            for d in dirs:
                if ".dist-info" in d:
                    dist_info_dir = d
                    break
            if entry_points and dist_info_dir:
                break
    else:
        if path.name == "entry_points.txt":
            entry_points = path
        for part in path.parts:
            if ".dist-info" in part:
                dist_info_dir = part
                break
    if not entry_points:
        raise RuntimeError(f"Could not find entry_points.txt under {path}")
    return entry_points, dist_info_dir


def generate_entry_point(
    entry_points_txt: pathlib.Path,
    out: pathlib.Path,
    console_script: str | None,
    console_script_guess: str,
    dist_info_dir: str = "",
) -> None:
    """Generate the entry point Python file."""
    entry_points_txt, auto_dist_info = find_entry_points_and_dist_info(entry_points_txt)
    if not dist_info_dir:
        dist_info_dir = auto_dist_info
    console_scripts = parse_entry_points(entry_points_txt)

    if not console_scripts:
        raise RuntimeError(
            f"No console_scripts found in {entry_points_txt}"
        )

    if console_script:
        if console_script not in console_scripts:
            available = ", ".join(sorted(console_scripts.keys()))
            raise RuntimeError(
                f"Console script '{console_script}' not found. "
                f"Available: {available}"
            )
        entry_point = console_scripts[console_script]
    else:
        # Try to guess based on the target name
        entry_point = console_scripts.get(console_script_guess)
        if not entry_point:
            available = ", ".join(sorted(console_scripts.keys()))
            raise RuntimeError(
                f"Could not guess console script from '{console_script_guess}'. "
                f"Available: {available}"
            )

    # Parse entry point specification (e.g., "flake8.main.cli:main")
    module, _, obj = entry_point.partition(":")
    attr, _, _ = obj.partition(".")

    content = _TEMPLATE.format(
        module=module,
        attr=attr,
        entry_point=obj,
        dist_info_dir=dist_info_dir,
    )

    out.write_text(content)


def main():
    parser = argparse.ArgumentParser(
        description="Generate console script entry point for Bazel"
    )
    parser.add_argument(
        "entry_points",
        type=pathlib.Path,
        help="Path to entry_points.txt or a directory containing it",
    )
    parser.add_argument(
        "out",
        type=pathlib.Path,
        help="Output file path",
    )
    parser.add_argument(
        "--console-script",
        help="Name of the console script to generate",
    )
    parser.add_argument(
        "--console-script-guess",
        default="",
        help="Name to guess if --console-script not provided",
    )
    parser.add_argument(
        "--dist-info-dir",
        default="",
        help="Path to dist-info directory for importlib_metadata support",
    )

    args = parser.parse_args()

    generate_entry_point(
        entry_points_txt=args.entry_points,
        out=args.out,
        console_script=args.console_script,
        console_script_guess=args.console_script_guess,
        dist_info_dir=args.dist_info_dir,
    )


if __name__ == "__main__":
    main()
