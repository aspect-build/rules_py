"""Regression test for pytest-xdist parallelism through py_test(pytest_main=True).

pytest-xdist is loaded as a pytest plugin when its dist-info is on
`sys.path`. When the test is invoked with `-n 2` (two workers), xdist
forks two subprocesses and distributes test cases between them. Each
worker reports its PID via the `worker_id` / `worker_input_info`
fixtures.

We dispatch four lightweight tests below and record each one's PID to
a shared on-disk log. The sentinel test at the bottom then reads the
log and asserts that at least two distinct PIDs served the four tests
— proving xdist actually ran in parallel rather than silently falling
back to a single process.

If xdist wiring regresses (plugin not discovered, `-n` swallowed,
worker subprocesses can't see pypi deps), the sentinel sees one PID
and the test fails.
"""

import os
import tempfile

# A shared file that every test writes its PID to. Living in a
# /tmp-based location keeps it outside the Bazel sandbox's per-test
# CWD so xdist workers (which may sandbox differently) can all reach it.
PID_LOG = os.path.join(
    tempfile.gettempdir(),
    f"pytest_xdist_regression_{os.environ.get('TEST_TARGET', 'local').replace('/', '_').replace(':', '_')}.log",
)


def _record_pid():
    # Append so concurrent writers from different workers don't clobber.
    with open(PID_LOG, "a") as f:
        f.write(f"{os.getpid()}\n")


def test_one():
    _record_pid()


def test_two():
    _record_pid()


def test_three():
    _record_pid()


def test_four():
    _record_pid()


def test_zzz_sentinel_verify_parallel_execution():
    # Name starts with `zzz` so pytest collection orders it last.
    # Assumption: pytest collection order correlates with test start
    # order within a single worker; across workers xdist's default
    # `load` scheduler spreads tests round-robin, so by the time the
    # sentinel starts the other four have at least been dispatched.
    with open(PID_LOG) as f:
        pids = {line.strip() for line in f if line.strip()}

    # Own PID is in there (the sentinel itself runs a test); at least
    # one other worker's PID should appear if xdist parallelized.
    assert len(pids) >= 2, (
        f"expected >= 2 distinct PIDs from pytest-xdist parallel workers, "
        f"got {len(pids)}: {pids!r}. If this is 1, xdist either didn't "
        f"load or didn't parallelize."
    )
