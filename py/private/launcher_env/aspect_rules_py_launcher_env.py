# -*- mode: python -*-
"""Bazel test-environment setup shared by the generated test launchers.

Both pytest_main.py and unittest_main.py import this before anything else
resolves the environment they set up, so the two drivers cannot drift apart.
"""

import os
from pathlib import Path
from typing import TYPE_CHECKING, Dict, Optional, Tuple

if TYPE_CHECKING:
    from coverage import Coverage

# coveragepy resolves manifest entries through symlinks; Bazel wants the
# original spelling back in the LCOV (coveragepy#963).
_absfile_mapping: Dict[str, str] = {}


def set_test_tmpdir() -> None:
    """Point the temp dir env vars at Bazel's per-test TEST_TMPDIR.

    Call before anything resolves a temp dir: `tempfile.gettempdir()` caches
    process-wide.

    Temp files then land in the test's private, writable temp directory instead
    of the system one, which is non-hermetic (leaks across parallel tests and
    runs) and unwritable-for-exec on remote-execution workers that mount /tmp
    `noexec` — a test that writes an executable helper into pytest's `tmp_path`
    and runs it gets EACCES. TMP/TEMP are set too so `tempfile` resolves
    consistently on Windows.
    """
    if "TEST_TMPDIR" not in os.environ:
        return
    for var in ("TMPDIR", "TMP", "TEMP"):
        os.environ[var] = os.environ["TEST_TMPDIR"]


def shard_info() -> Optional[Tuple[int, int]]:
    """https://bazel.build/reference/test-encyclopedia#initial-conditions"""
    index = os.environ.get("TEST_SHARD_INDEX")
    total = os.environ.get("TEST_TOTAL_SHARDS")
    if not (index and total and int(total) > 1):
        return None
    return int(index), int(total)


def advertise_sharding() -> None:
    """Call before any early return, else Bazel masks the real error with 'the
    test runner did not advertise support for test sharding'."""
    status = os.environ.get("TEST_SHARD_STATUS_FILE")
    if status and shard_info():
        Path(status).touch()


def start_coverage() -> Optional["Coverage"]:
    """Start a coverage session over the files Bazel asked to instrument.

    Bazel sets COVERAGE_MANIFEST for a target carrying InstrumentedFilesInfo
    (https://bazel.build/rules/lib/providers/InstrumentedFilesInfo); its lines
    are the files that matched --instrumentation_filter. Returns None when
    coverage is not enabled or the `coverage` package is not a dependency.
    """
    global _absfile_mapping

    if "COVERAGE_MANIFEST" not in os.environ:
        return None
    try:
        import coverage
        import coverage.files
    except ModuleNotFoundError as e:
        print("WARNING: python coverage setup failed. Do you need to include the 'coverage' package as a dependency of the test target?", e)
        return None

    with open(os.environ["COVERAGE_MANIFEST"], "r") as mf:
        manifest_entries = mf.read().splitlines()
    cov = coverage.Coverage(include=manifest_entries)
    _absfile_mapping = {coverage.files.abs_file(mfe): mfe for mfe in manifest_entries}
    cov.start()
    return cov


def write_lcov(cov: "Coverage") -> None:
    """Stop `cov` and write Bazel's LCOV output file.

    https://bazel.build/configure/coverage
    """
    cov.stop()
    output_file = os.getenv("COVERAGE_OUTPUT_FILE")
    assert output_file is not None

    unfixed = output_file + ".tmp"
    cov.lcov_report(outfile=unfixed)
    cov.save()

    with open(unfixed, "r") as src, open(output_file, "w") as dst:
        for line in src:
            # Undo coveragepy's symlink-following of source paths
            # (coveragepy#963).
            if line.startswith("SF:"):
                sourcefile = line[3:].rstrip()
                if sourcefile in _absfile_mapping:
                    dst.write("SF:%s\n" % _absfile_mapping[sourcefile])
                    continue
            # Drop the 'end line number' field Bazel rejects (bazel#25118).
            if line.startswith("FN:"):
                parts = line[3:].split(",")
                if len(parts) == 3:
                    dst.write("FN:%s,%s" % (parts[0], parts[2]))
                    continue
            dst.write(line)
    os.unlink(unfixed)
