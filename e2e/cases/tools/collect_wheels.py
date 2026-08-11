"""Copy every .whl reachable from the given paths into one output directory.

Ported from rules_pycross (tests/e2e/shared/collect_wheels.py). Inputs are
tree artifacts holding wheels — pep517_whl/pep517_native_whl declare a
directory output. The same anyarch wheel can arrive through more than one
platform transition, so first copy wins.
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
            for whl in Path(p).glob("*.whl"):
                real_path = whl.resolve()
                target_path = out_dir / real_path.name
                if not target_path.exists():
                    shutil.copy2(real_path, target_path)


if __name__ == "__main__":
    main()
