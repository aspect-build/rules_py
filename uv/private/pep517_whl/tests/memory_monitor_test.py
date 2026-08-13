import contextlib
import io
import itertools
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from typing import Dict, List, Optional
from unittest import mock

from uv.private.pep517_whl import memory_monitor


class MemoryMonitorTest(unittest.TestCase):
    def test_sums_descendants_spawned_by_any_task(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            self._write_process(proc_root, 10, 2, {10: [20], 11: [30]})
            self._write_process(proc_root, 20, 3, {20: []})
            self._write_process(proc_root, 30, 5, {30: []})

            self.assertEqual(
                10 * 4096,
                memory_monitor._process_tree_rss_bytes(10, 4096, str(proc_root)),
            )

    def test_walks_children_when_parent_rss_disappears(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            self._write_process(proc_root, 10, None, {10: [20]})
            self._write_process(proc_root, 20, 3, {20: []})

            self.assertEqual(
                3 * 4096,
                memory_monitor._process_tree_rss_bytes(10, 4096, str(proc_root)),
            )

    def test_preserves_peak_after_sampling_failure(self) -> None:
        stderr = io.StringIO()
        with (
            tempfile.TemporaryFile() as stdout,
            contextlib.redirect_stderr(stderr),
            mock.patch.object(memory_monitor.sys, "platform", "linux"),
            mock.patch.object(memory_monitor.os.path, "isdir", return_value=True),
            mock.patch.object(memory_monitor, "_SAMPLE_INTERVAL_SECONDS", 0.01),
            mock.patch.object(
                memory_monitor,
                "_process_tree_rss_bytes",
                side_effect=itertools.chain(
                    [16 * memory_monitor._MIB],
                    itertools.repeat(OSError("procfs race")),
                ),
            ),
        ):
            memory_monitor.run_with_memory_monitor(
                [sys.executable, "-c", "import time; time.sleep(.05)"],
                cwd=None,
                env=os.environ.copy(),
                stdout=stdout,
                wheel="test-wheel.tar.gz",
            )

        self.assertIn("peak=16.0 MiB", stderr.getvalue())

    @unittest.skipUnless(
        sys.platform.startswith("linux") and os.path.isdir("/proc"),
        "requires Linux procfs",
    )
    def test_failure_reports_peak_and_raises_child_returncode(self) -> None:
        stderr = io.StringIO()
        with (
            tempfile.TemporaryFile() as stdout,
            contextlib.redirect_stderr(stderr),
            mock.patch.object(memory_monitor, "_REPORT_STEP_BYTES", 1),
        ):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                memory_monitor.run_with_memory_monitor(
                    [
                        sys.executable,
                        "-c",
                        "import time; "
                        "data = bytearray(16 * 1024 * 1024); "
                        "time.sleep(.5); "
                        "raise SystemExit(7)",
                    ],
                    cwd=None,
                    env=os.environ.copy(),
                    stdout=stdout,
                    wheel="test-wheel.tar.gz",
                )

        self.assertEqual(7, raised.exception.returncode)
        self.assertRegex(stderr.getvalue(), r"peak=[1-9][0-9.]* MiB, return code=7")

    @unittest.skipUnless(hasattr(signal, "SIGKILL"), "requires SIGKILL")
    def test_sigkill_is_reported_as_a_possible_oom(self) -> None:
        stderr = io.StringIO()
        with (
            tempfile.TemporaryFile() as stdout,
            contextlib.redirect_stderr(stderr),
        ):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                memory_monitor.run_with_memory_monitor(
                    [
                        sys.executable,
                        "-c",
                        "import os, signal, time; "
                        "data = bytearray(16 * 1024 * 1024); "
                        "time.sleep(.5); "
                        "os.kill(os.getpid(), signal.SIGKILL)",
                    ],
                    cwd=None,
                    env=os.environ.copy(),
                    stdout=stdout,
                    wheel="test-wheel.tar.gz",
                )

        self.assertEqual(-signal.SIGKILL, raised.exception.returncode)
        self.assertIn("SIGKILL; possible OOM", stderr.getvalue())

    @unittest.skipUnless(hasattr(os, "getpgrp"), "requires POSIX process groups")
    def test_child_stays_in_callers_process_group(self) -> None:
        with (
            tempfile.TemporaryFile(mode="w+") as stdout,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            memory_monitor.run_with_memory_monitor(
                [sys.executable, "-c", "import os; print(os.getpgrp())"],
                cwd=None,
                env=os.environ.copy(),
                stdout=stdout,
                wheel="test-wheel.tar.gz",
            )
            stdout.seek(0)
            child_process_group = int(stdout.read())

        self.assertEqual(os.getpgrp(), child_process_group)

    @staticmethod
    def _write_process(
        proc_root: Path,
        pid: int,
        rss_pages: Optional[int],
        task_children: Dict[int, List[int]],
    ) -> None:
        process_dir = proc_root / str(pid)
        process_dir.mkdir()
        if rss_pages is not None:
            (process_dir / "statm").write_text(
                "100 {} 0 0 0 0 0\n".format(rss_pages)
            )
        for task_id, children in task_children.items():
            task_dir = process_dir / "task" / str(task_id)
            task_dir.mkdir(parents=True)
            (task_dir / "children").write_text(
                " ".join(str(child) for child in children)
            )


if __name__ == "__main__":
    unittest.main()
