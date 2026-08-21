"""Every lock in this case must keep reproducing #1394.

The scenarios differ in what rules_py *does* with the mismatched wheel, so their
install assertions can't be shared — `dep_group` binds a target to exactly one
project. What is shared is the premise: each lock still has to record a wheel
whose filename and `.dist-info` disagree. A lock bumped to an escaped filename
would leave the scenario passing while testing nothing, so the guards run once
here rather than being restated in each.

Four scenarios pin `InquirerPy-0.3.4-py3-none-any.whl`, whose archive ships
`inquirerpy-0.3.4.dist-info`. `archive-prefix` pins the opposite shape —
`actioneer-0.0.1-py3-none-any.whl`, already escaped, over an archive that ships
`Actioneer-0.0.1.dist-info` — so its premise is that the filename stays
normalized.
"""

import tomllib
import unittest
from pathlib import Path

from bazel_tools.tools.python.runfiles import runfiles

_SCENARIOS = ("prebuilt-wheel", "no-binary", "override-target", "unbuilt")
_MISMATCHED_WHEEL = "InquirerPy-0.3.4-py3-none-any.whl"
_NORMALIZED_WHEEL = "actioneer-0.0.1-py3-none-any.whl"


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

    def test_archive_prefix_lock_keeps_a_normalized_filename(self) -> None:
        # The inverse premise: nothing about this filename hints that the
        # implied `.dist-info` is a guess, which is what makes it get stripped
        # as an archive path prefix instead of discovered.
        lock = Path(
            runfiles.Create().Rlocation(
                "_main/uv-dist-info-case-1394/archive-prefix/uv.lock"
            )
        )
        filenames = _wheel_filenames(lock, "actioneer")
        self.assertEqual([_NORMALIZED_WHEEL], filenames)
        project, version = filenames[0].split("-")[:2]
        self.assertEqual(project, project.lower().replace(".", "_"), filenames)
        self.assertEqual("0.0.1", version, filenames)


if __name__ == "__main__":
    unittest.main()
