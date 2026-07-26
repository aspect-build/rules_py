"""Regression test for pytest-xdist parallelism through py_pytest_test.

pytest-xdist is loaded as a pytest plugin when its dist-info is on
`sys.path`. When the test is invoked with `-n 2` (two workers), xdist
forks two subprocesses and distributes test cases between them. Each
worker reports its PID via the `worker_id` / `worker_input_info`
fixtures.

We dispatch four lightweight tests below and record each one's PID to
a shared on-disk log. The sentinel test at the bottom then waits for
the log to show at least two distinct PIDs — proving xdist actually
ran in parallel rather than silently falling back to a single process.

If xdist wiring regresses (plugin not discovered, `-n` swallowed,
worker subprocesses can't see pypi deps), the sentinel sees one PID
and the test fails.
"""

import os
import tempfile
import time

# A shared file that every test writes its PID to. Living in a
# /tmp-based location keeps it outside the Bazel sandbox's per-test
# CWD so xdist workers (which may sandbox differently) can all reach it.
PID_LOG = os.path.join(
    tempfile.gettempdir(),
    f"pytest_xdist_regression_{os.environ.get('TEST_TARGET', 'local').replace('/', '_').replace(':', '_')}.log",
)


# Generous: only reached when xdist genuinely failed to parallelize.
_SENTINEL_TIMEOUT_S = 30


def _record_pid() -> None:
    # Append so concurrent writers from different workers don't clobber.
    with open(PID_LOG, "a") as f:
        f.write(f"{os.getpid()}\n")


def test_one() -> None:
    _record_pid()


def test_two() -> None:
    _record_pid()


def test_three() -> None:
    _record_pid()


def test_four() -> None:
    _record_pid()


def test_zzz_sentinel_verify_parallel_execution() -> None:
    # Collection order says nothing about when other workers write, so poll
    # until a second worker checks in rather than reading the log once.
    # A single-process fallback never produces a second PID and times out.
    deadline = time.monotonic() + _SENTINEL_TIMEOUT_S
    pids = set()
    while True:
        try:
            with open(PID_LOG) as f:
                pids = {line.strip() for line in f if line.strip()}
        except FileNotFoundError:
            pids = set()

        if len(pids) >= 2:
            return
        if time.monotonic() >= deadline:
            break
        time.sleep(0.05)

    raise AssertionError(
        f"expected >= 2 distinct PIDs from pytest-xdist parallel workers, "
        f"got {len(pids)}: {pids!r} after waiting {_SENTINEL_TIMEOUT_S}s. "
        f"If this is 1, xdist either didn't load or didn't parallelize."
    )
