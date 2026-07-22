"""Verify pytest collects only the expected test and no spurious files.

This catches regressions where generated main scripts or other artifacts
sneak into pytest's collection.
"""

import subprocess
import sys
import os


def test_no_spurious_collection() -> None:
    """Run pytest --collect-only on ourselves and verify the collected count."""
    # Collect exactly the files the real test would. The .pytest_paths file
    # lists this target's declared test sources.
    target = os.environ.get("BAZEL_TARGET", "")
    target_name = os.environ.get("BAZEL_TARGET_NAME", "")
    package = target.split(":")[0].lstrip("/")
    paths_file = os.path.join(package, target_name + ".pytest_paths")

    args = [sys.executable, "-m", "pytest", "--collect-only", "-q"]

    if os.path.isfile(paths_file):
        with open(paths_file) as f:
            for line in f:
                d = line.strip()
                if d and os.path.exists(d):
                    args.append(d)

    result = subprocess.run(args, capture_output=True, text=True)

    # The only test in our srcs is this file, containing this one test function.
    # If pytest discovered a generated main or other spurious module, the count
    # would be higher or there would be import errors.
    collected_lines = [
        l for l in result.stdout.splitlines()
        if "test_no_spurious_collection" in l
    ]
    assert len(collected_lines) == 1, (
        f"Expected exactly 1 collected test, got:\n{result.stdout}\nstderr:\n{result.stderr}"
    )

    # No errors or import failures
    assert result.returncode == 0, (
        f"pytest --collect-only failed (rc={result.returncode}):\n{result.stdout}\n{result.stderr}"
    )
