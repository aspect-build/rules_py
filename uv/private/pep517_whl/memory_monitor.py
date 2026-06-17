"""Run a wheel build while reporting its aggregate process-tree memory."""

import os
import subprocess
import sys
import time

_MIB = 1024 * 1024
_REPORT_STEP_BYTES = 256 * _MIB
_SAMPLE_INTERVAL_SECONDS = 0.25


def _process_tree_rss_bytes(root_pid, page_size, proc_root="/proc"):
    """Return aggregate RSS for root_pid and its descendants on Linux."""
    # statm reports resident memory in pages:
    # https://man7.org/linux/man-pages/man5/proc_pid_statm.5.html
    #
    # Each task's children file lists only immediate children, so recurse:
    # https://docs.kernel.org/filesystems/proc.html#proc-pid-task-tid-children-information-about-task-children
    pending = [root_pid]
    seen = set()
    total = 0
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        process_dir = os.path.join(proc_root, str(pid))

        try:
            with open(os.path.join(process_dir, "statm")) as statm:
                total += int(statm.read().split()[1]) * page_size
            task_ids = os.listdir(os.path.join(process_dir, "task"))
        except (
            FileNotFoundError,
            PermissionError,
            ProcessLookupError,
            ValueError,
            IndexError,
        ):
            continue

        for task_id in task_ids:
            try:
                with open(os.path.join(process_dir, "task", task_id, "children")) as children:
                    pending.extend(int(child) for child in children.read().split())
            except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
                continue

    return total


def _report_memory(wheel, state, current, peak):
    if peak is None:
        details = "unavailable"
    elif current is None:
        details = "sampled aggregate peak={:.1f} MiB".format(peak / _MIB)
    else:
        details = "sampled aggregate current={:.1f} MiB, peak={:.1f} MiB".format(
            current / _MIB,
            peak / _MIB,
        )
    print(
        "rules_py wheel build memory for {} {}: {}".format(
            wheel,
            state,
            details,
        ),
        file=sys.stderr,
        flush=True,
    )


def run_with_memory_profile(cmd, *, cwd, env, stdout, wheel):
    """Run cmd and raise CalledProcessError after reporting peak memory."""
    process = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdout=stdout,
        stderr=subprocess.STDOUT,
    )
    can_sample_proc = sys.platform.startswith("linux") and os.path.isdir("/proc")
    peak = 0 if can_sample_proc else None
    page_size = os.sysconf("SC_PAGE_SIZE") if can_sample_proc else None
    next_report = _REPORT_STEP_BYTES

    while True:
        if can_sample_proc:
            current = _process_tree_rss_bytes(process.pid, page_size)
            peak = max(peak, current)
            if peak >= next_report:
                _report_memory(wheel, "running", current, peak)
                next_report = (peak // _REPORT_STEP_BYTES + 1) * _REPORT_STEP_BYTES

        returncode = process.poll()
        if returncode is not None:
            break
        time.sleep(_SAMPLE_INTERVAL_SECONDS)

    _report_memory(wheel, "finished", None, peak or None)
    if returncode:
        raise subprocess.CalledProcessError(returncode, cmd)
