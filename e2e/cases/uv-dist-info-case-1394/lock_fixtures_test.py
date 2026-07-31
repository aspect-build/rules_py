"""Every lock in this case must keep reproducing #1394.

The four scenarios differ in what rules_py *does* with the mismatched wheel, so
their install assertions can't be shared — `dep_group` binds a target to exactly
one project. What is shared is the premise: each lock still has to record
`InquirerPy-0.3.4-py3-none-any.whl`, whose archive ships
`inquirerpy-0.3.4.dist-info`. A lock bumped to an escaped filename would leave
every scenario passing while testing nothing, so the guard runs once over all
four rather than being restated in each.
"""

import tomllib
import unittest
from pathlib import Path

from bazel_tools.tools.python.runfiles import runfiles

_SCENARIOS = ("prebuilt-wheel", "no-binary", "override-target", "unbuilt")
_MISMATCHED_WHEEL = "InquirerPy-0.3.4-py3-none-any.whl"


def _wheel_filenames(lock: Path, package: str) -> list[str]:
    with lock.open("rb") as f:
        locked = tomllib.load(f)
    return [
        wheel["url"].rsplit("/", 1)[-1]
        for entry in locked["package"]
        if entry["name"] == package
        for wheel in entry.get("wheels", [])
    ]


class LockFixturesTest(unittest.TestCase):
    def test_every_lock_records_the_mismatched_wheel(self) -> None:
        run = runfiles.Create()
        for scenario in _SCENARIOS:
            with self.subTest(scenario=scenario):
                lock = Path(
                    run.Rlocation(
                        f"_main/uv-dist-info-case-1394/{scenario}/uv.lock"
                    )
                )
                self.assertEqual(
                    [_MISMATCHED_WHEEL],
                    _wheel_filenames(lock, "inquirerpy"),
                    f"{scenario} no longer pins a wheel whose filename and "
                    ".dist-info differ, so it stops covering #1394",
                )

    def test_prebuilt_wheel_lock_keeps_unescaped_filenames(self) -> None:
        # These two agree with their own `.dist-info`, but their filenames are
        # unescaped, so they still take the discovery path rather than the
        # strip-the-implied-prefix fast path.
        lock = Path(
            runfiles.Create().Rlocation(
                "_main/uv-dist-info-case-1394/prebuilt-wheel/uv.lock"
            )
        )
        for package in ("xlsxwriter", "jaraco-classes"):
            with self.subTest(package=package):
                filenames = _wheel_filenames(lock, package)
                self.assertEqual(1, len(filenames), filenames)
                project = filenames[0].split("-")[0]
                self.assertNotEqual(
                    project,
                    project.lower().replace(".", "_"),
                    f"{filenames[0]} is now escaped, so it no longer "
                    "exercises discovery",
                )


if __name__ == "__main__":
    unittest.main()
