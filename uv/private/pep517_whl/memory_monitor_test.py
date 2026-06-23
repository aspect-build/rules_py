import contextlib
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
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

    def test_missing_children_file_warns_and_covers_only_root(self):
        """When children files are absent (CONFIG_PROC_CHILDREN missing), the walk
        stops at the root PID and emits a one-time warning to stderr."""
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)

            process_dir = proc_root / "10"
            process_dir.mkdir()
            (process_dir / "statm").write_text("100 5 0 0 0 0 0\n")
            (process_dir / "task" / "10").mkdir(parents=True)
            child_dir = proc_root / "20"
            child_dir.mkdir()
            (child_dir / "statm").write_text("100 3 0 0 0 0 0\n")

            with (
                contextlib.redirect_stderr(stderr),
                mock.patch.object(memory_monitor, "_children_unavailable_warned", False),
            ):
                result = memory_monitor._process_tree_rss_bytes(10, 4096, str(proc_root))

        self.assertEqual(5 * 4096, result)  # only root PID; process 20 unreachable
        self.assertIn("CONFIG_PROC_CHILDREN", stderr.getvalue())

    def test_success_without_monitoring_uses_run(self):
        with tempfile.TemporaryFile() as stdout:
            memory_monitor.run_with_memory_profile(
                [sys.executable, "-c", "pass"],
                cwd=None,
                env=os.environ.copy(),
                stdout=stdout,
                wheel="test-wheel.tar.gz",
                monitor=False,
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
                    monitor=True,
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

    def test_sampler_failure_reports_unavailable(self):
        stderr = io.StringIO()
        with (
            tempfile.TemporaryFile() as stdout,
            contextlib.redirect_stderr(stderr),
            mock.patch.object(memory_monitor.sys, "platform", "linux"),
            mock.patch.object(memory_monitor.os.path, "isdir", return_value=True),
            mock.patch.object(
                memory_monitor,
                "_process_tree_rss_bytes",
                side_effect=OSError("procfs unavailable"),
            ),
        ):
            memory_monitor.run_with_memory_profile(
                [sys.executable, "-c", "import time; time.sleep(.1)"],
                cwd=None,
                env=os.environ.copy(),
                stdout=stdout,
                wheel="test-wheel.tar.gz",
                monitor=True,
            )

        self.assertIn(
            "wheel build memory for test-wheel.tar.gz finished: unavailable",
            stderr.getvalue(),
        )

    def test_unsupported_platform_uses_run(self):
        stderr = io.StringIO()
        with (
            tempfile.TemporaryFile() as stdout,
            contextlib.redirect_stderr(stderr),
            mock.patch.object(memory_monitor.sys, "platform", "win32"),
            mock.patch.object(memory_monitor.subprocess, "run") as run,
        ):
            memory_monitor.run_with_memory_profile(
                ["command"],
                cwd=None,
                env={},
                stdout=stdout,
                wheel="test-wheel.tar.gz",
                monitor=True,
            )

        run.assert_called_once()
        self.assertIn(
            "wheel build memory for test-wheel.tar.gz finished: unavailable",
            stderr.getvalue(),
        )

    @unittest.skipUnless(
        sys.platform.startswith("linux") and os.path.isdir("/proc"),
        "requires Linux procfs",
    )
    def test_exception_kills_and_waits_for_process_tree(self):
        for interrupt_signal, expected_exception in (
            (signal.SIGINT, KeyboardInterrupt),
            (signal.SIGTERM, SystemExit),
        ):
            with (
                self.subTest(signal=interrupt_signal),
                tempfile.TemporaryDirectory() as directory,
                tempfile.TemporaryFile() as stdout,
            ):
                pids_file = Path(directory) / "pids"
                with self.assertRaises(expected_exception) as raised:
                    memory_monitor.run_with_memory_profile(
                        [
                            sys.executable,
                            "-c",
                            "import os, pathlib, signal, subprocess, sys, time; "
                            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                            "pathlib.Path(sys.argv[1]).write_text(f'{os.getpid()} {child.pid}'); "
                            "os.kill(os.getppid(), int(sys.argv[2])); "
                            "time.sleep(60)",
                            str(pids_file),
                            str(int(interrupt_signal)),
                        ],
                        cwd=None,
                        env=os.environ.copy(),
                        stdout=stdout,
                        wheel="test-wheel.tar.gz",
                        monitor=True,
                    )

                if interrupt_signal == signal.SIGTERM:
                    self.assertEqual(128 + signal.SIGTERM, raised.exception.code)

                frontend_pid, child_pid = [
                    int(pid) for pid in pids_file.read_text().split()
                ]
                for pid in (frontend_pid, child_pid):
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            break
                        if time.monotonic() >= deadline:
                            self.fail(
                                "process {} survived interruption cleanup".format(pid)
                            )
                        time.sleep(0.01)

    @staticmethod
    def _write_process(proc_root, pid, rss_pages, task_children):
        process_dir = proc_root / str(pid)
        process_dir.mkdir()
        (process_dir / "statm").write_text("100 {} 0 0 0 0 0\n".format(rss_pages))
        for task_id, children in task_children.items():
            task_dir = process_dir / "task" / str(task_id)
            task_dir.mkdir(parents=True)
            (task_dir / "children").write_text(
                " ".join(str(child) for child in children)
            )


if __name__ == "__main__":
    unittest.main()
