"""Copy the given .whl files into one output directory.

Ported from rules_pycross (tests/e2e/shared/collect_wheels.py). Inputs are
wheel files under fixed analysis-time names, so each copy is prefixed with its
configuration directory and parent directory (the wheel's repo) to keep both
per-platform variants and same-named wheels from different repos distinct.
"""

import argparse
import shutil
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("wheel", nargs="*")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for wheel_str in args.wheel:
        for p in wheel_str.split(" "):
            whl = Path(p)
            config = whl.parts[1] if whl.parts[0] == "bazel-out" else "source"
            target_path = out_dir / "{}-{}-{}".format(config, whl.parent.name, whl.name)
            shutil.copy2(whl.resolve(), target_path)


if __name__ == "__main__":
    main()
