import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from uv.private.pep517_whl import memory_monitor


class ProcessTreeRssTest(unittest.TestCase):
    def test_sums_descendants_spawned_by_any_task(self):
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            self._write_process(proc_root, 10, 2, {10: [20], 11: [30]})
            self._write_process(proc_root, 20, 3, {20: []})
            self._write_process(proc_root, 30, 5, {30: []})

            self.assertEqual(
                10 * 4096,
                memory_monitor._process_tree_rss_bytes(10, 4096, str(proc_root)),
            )

    def test_failed_child_reports_memory_before_raising(self):
        stderr = io.StringIO()
        with (
            tempfile.TemporaryFile() as stdout,
            contextlib.redirect_stderr(stderr),
            mock.patch.object(memory_monitor, "_REPORT_STEP_BYTES", 1),
        ):
            with self.assertRaisesRegex(subprocess.CalledProcessError, "exit status 7"):
                memory_monitor.run_with_memory_profile(
                    [
                        sys.executable,
                        "-c",
                        "import time; data = bytearray(16 * 1024 * 1024); time.sleep(.5); raise SystemExit(7)",
                    ],
                    cwd=None,
                    env=os.environ.copy(),
                    stdout=stdout,
                    wheel="test-wheel.tar.gz",
                )

        report = stderr.getvalue()
        if sys.platform.startswith("linux") and os.path.isdir("/proc"):
            self.assertRegex(
                report,
                r"wheel build memory for test-wheel[.]tar[.]gz running: sampled aggregate current=[1-9][0-9.]* MiB, peak=[1-9][0-9.]* MiB",
            )
            self.assertRegex(
                report,
                r"wheel build memory for test-wheel[.]tar[.]gz finished: sampled aggregate peak=[1-9][0-9.]* MiB",
            )
        else:
            self.assertIn(
                "wheel build memory for test-wheel.tar.gz finished: unavailable",
                report,
            )

    def test_reports_unavailable_memory_instead_of_zero(self):
        stderr = io.StringIO()
        with (
            tempfile.TemporaryFile() as stdout,
            contextlib.redirect_stderr(stderr),
            mock.patch.object(memory_monitor.sys, "platform", "win32"),
        ):
            memory_monitor.run_with_memory_profile(
                [sys.executable, "-c", "pass"],
                cwd=None,
                env=os.environ.copy(),
                stdout=stdout,
                wheel="test-wheel.tar.gz",
            )

        self.assertIn(
            "wheel build memory for test-wheel.tar.gz finished: unavailable",
            stderr.getvalue(),
        )

    @staticmethod
    def _write_process(proc_root, pid, rss_pages, task_children):
        process_dir = proc_root / str(pid)
        process_dir.mkdir()
        (process_dir / "statm").write_text("100 {} 0 0 0 0 0\n".format(rss_pages))
        for task_id, children in task_children.items():
            task_dir = process_dir / "task" / str(task_id)
            task_dir.mkdir(parents=True)
            (task_dir / "children").write_text(" ".join(str(child) for child in children))


if __name__ == "__main__":
    unittest.main()
