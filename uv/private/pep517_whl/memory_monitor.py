"""Report approximate Linux RSS while a wheel build runs."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from typing import IO, Mapping, Optional, Sequence

_MIB = 1024 * 1024
_REPORT_STEP_BYTES = 256 * _MIB
_SAMPLE_INTERVAL_SECONDS = 0.25


def _process_tree_rss_bytes(
    root_pid: int,
    page_size: int,
    proc_root: str = "/proc",
) -> Optional[int]:
    """Return the sampled RSS sum for root_pid and its descendants."""
    # statm reports resident memory in pages:
    # https://man7.org/linux/man-pages/man5/proc_pid_statm.5.html
    # Each task's children file lists that task's immediate children:
    # https://docs.kernel.org/filesystems/proc.html#proc-pid-task-tid-children-information-about-task-children
    pending = [root_pid]
    seen = set()
    total = 0
    sampled = False

    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        process_dir = os.path.join(proc_root, str(pid))

        try:
            with open(os.path.join(process_dir, "statm")) as statm:
                total += int(statm.read().split()[1]) * page_size
            sampled = True
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError):
            pass

        try:
            task_ids = os.listdir(os.path.join(process_dir, "task"))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue

        for task_id in task_ids:
            try:
                with open(os.path.join(process_dir, "task", task_id, "children")) as children:
                    pending.extend(int(child) for child in children.read().split())
            except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
                continue

    return total if sampled else None


def _report_memory(
    wheel: str,
    state: str,
    peak: Optional[int],
    current: Optional[int] = None,
    returncode: Optional[int] = None,
) -> None:
    if peak is None:
        details = "unavailable"
    elif current is None:
        details = "peak={:.1f} MiB".format(peak / _MIB)
    else:
        details = "current={:.1f} MiB, peak={:.1f} MiB".format(
            current / _MIB,
            peak / _MIB,
        )
    if returncode is not None:
        details += ", return code={}".format(returncode)
        if returncode == -9:
            details += " (SIGKILL; possible OOM)"
    print(
        "rules_py wheel build memory for {} {}: {} (approximate aggregate RSS)".format(
            wheel,
            state,
            details,
        ),
        file=sys.stderr,
        flush=True,
    )


def run_with_memory_monitor(
    cmd: Sequence[str],
    *,
    cwd: str,
    env: Mapping[str, str],
    stdout: IO[str],
    wheel: str,
) -> None:
    """Run cmd while reporting best-effort process-tree RSS."""
    try:
        can_sample = sys.platform.startswith("linux") and os.path.isdir("/proc")
        page_size = os.sysconf("SC_PAGE_SIZE") if can_sample else None
    except (OSError, ValueError):
        can_sample = False
        page_size = None

    process = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdout=stdout,
        stderr=subprocess.STDOUT,
    )
    peak = None
    next_report = 0

    while True:
        if can_sample:
            assert page_size is not None
            try:
                current = _process_tree_rss_bytes(process.pid, page_size)
            except (OSError, ValueError):
                current = None
            if current is not None:
                peak = current if peak is None else max(peak, current)
                if peak >= next_report:
                    _report_memory(wheel, "running", peak, current=current)
                    next_report = (peak // _REPORT_STEP_BYTES + 1) * _REPORT_STEP_BYTES

        returncode = process.poll()
        if returncode is not None:
            break
        time.sleep(_SAMPLE_INTERVAL_SECONDS)

    _report_memory(wheel, "finished", peak, returncode=returncode)
    if returncode:
        raise subprocess.CalledProcessError(returncode, cmd)
