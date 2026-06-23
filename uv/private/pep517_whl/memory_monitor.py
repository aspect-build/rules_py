"""Run a wheel build while reporting its aggregate process-tree memory."""

import os
import signal
import subprocess
import sys
import time

_MIB = 1024 * 1024
_REPORT_STEP_BYTES = 256 * _MIB
_SAMPLE_INTERVAL_SECONDS = 0.25


def _exit_on_sigterm(signum, _frame):
    raise SystemExit(128 + signum)


_children_unavailable_warned = False


def _process_tree_rss_bytes(root_pid, page_size, proc_root="/proc"):
    """Return aggregate RSS for root_pid and its descendants on Linux."""
    global _children_unavailable_warned
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

        any_children_file_found = False
        for task_id in task_ids:
            try:
                with open(
                    os.path.join(process_dir, "task", task_id, "children")
                ) as children:
                    pending.extend(int(child) for child in children.read().split())
                any_children_file_found = True
            except FileNotFoundError:
                pass  # children file absent; may indicate missing CONFIG_PROC_CHILDREN
            except (PermissionError, ProcessLookupError, ValueError):
                any_children_file_found = True  # file exists; transient access error
                continue

        if task_ids and not any_children_file_found and not _children_unavailable_warned:
            _children_unavailable_warned = True
            print(
                "rules_py: /proc/{pid}/task/{tid}/children is unavailable; "
                "memory sampling covers only the root process "
                "(kernel may lack CONFIG_PROC_CHILDREN).",
                file=sys.stderr,
                flush=True,
            )

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


def run_with_memory_profile(cmd, *, cwd, env, stdout, wheel, monitor):
    """Run cmd, optionally reporting process-tree memory."""
    _sp_kwargs = {"cwd": cwd, "env": env, "stdout": stdout, "stderr": subprocess.STDOUT}

    if not monitor:
        subprocess.run(cmd, check=True, **_sp_kwargs)
        return

    can_sample_proc = sys.platform.startswith("linux") and os.path.isdir("/proc")
    try:
        page_size = os.sysconf("SC_PAGE_SIZE") if can_sample_proc else None
    except (OSError, ValueError):
        can_sample_proc = False
        page_size = None

    if not can_sample_proc:
        try:
            subprocess.run(cmd, check=True, **_sp_kwargs)
        except subprocess.CalledProcessError:
            _report_memory(wheel, "finished", None, None)
            raise
        _report_memory(wheel, "finished", None, None)
        return

    previous_sigterm_handler = signal.signal(signal.SIGTERM, _exit_on_sigterm)
    process = None

    try:
        process = subprocess.Popen(
            cmd,
            start_new_session=True,
            **_sp_kwargs,
        )
        peak = 0
        next_report = _REPORT_STEP_BYTES

        while True:
            if can_sample_proc:
                try:
                    current = _process_tree_rss_bytes(process.pid, page_size)
                except (OSError, ValueError):
                    can_sample_proc = False
                    peak = None
                else:
                    peak = max(peak, current)
                    if peak >= next_report:
                        _report_memory(wheel, "running", current, peak)
                        next_report = (
                            peak // _REPORT_STEP_BYTES + 1
                        ) * _REPORT_STEP_BYTES

            returncode = process.poll()
            if returncode is not None:
                break
            time.sleep(_SAMPLE_INTERVAL_SECONDS)
    except BaseException:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)

    _report_memory(wheel, "finished", None, peak or None)
    if returncode:
        raise subprocess.CalledProcessError(returncode, cmd)
