"""Copy every .whl reachable from the given paths into one output directory.

Ported from rules_pycross (tests/e2e/shared/collect_wheels.py). Inputs are a
mix of plain wheel files and tree artifacts holding wheels, because
pep517_whl/pep517_native_whl declare a directory output.
"""

import argparse
import shutil
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("wheel", nargs="*", default=[])
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for wheel_str in args.wheel:
        for p in wheel_str.split(" "):
            wheel_path = Path(p)

            if wheel_path.is_dir():
                for whl in wheel_path.glob("*.whl"):
                    real_path = whl.resolve()
                    target_path = out_dir / real_path.name
                    if not target_path.exists():
                        shutil.copy2(real_path, target_path)
                continue

            if not wheel_path.name.endswith(".whl"):
                continue

            real_path = wheel_path.resolve()
            target_path = out_dir / real_path.name
            if target_path.exists():
                continue

            shutil.copy2(real_path, target_path)


if __name__ == "__main__":
    main()
