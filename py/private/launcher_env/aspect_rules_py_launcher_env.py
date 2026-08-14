# -*- mode: python -*-
"""Bazel test-environment setup shared by the generated test launchers.

Both pytest_main.py and unittest_main.py import this before anything else
resolves the environment they set up, so the two drivers cannot drift apart.
"""

import atexit
import hashlib
import os
import stat
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from coverage import Coverage

# coveragepy resolves manifest entries through symlinks; Bazel wants the
# original spelling back in the LCOV (coveragepy#963).
_absfile_mapping: dict[str, str] = {}


def _alias_dir() -> str | None:
    """A short directory to hold temp dir aliases, or None if this host won't
    give us one only we can write to.

    Traversable by others (0711) so a test that drops privileges can still
    reach its own TMPDIR; planting an alias needs write, which they lack.
    """
    path = "/tmp/rpy-%d" % os.getuid()
    try:
        os.mkdir(path, 0o711)
        return path
    except FileExistsError:
        pass
    except OSError:
        return None
    # Only reuse an existing entry nobody else can write to; otherwise the
    # aliases inside it are attacker-controlled.
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        return None
    return path if not stat.S_IMODE(st.st_mode) & 0o022 else None


def _unlink_alias(path: str, owner_pid: int) -> None:
    # A fork inherits atexit callbacks, so a child exiting normally would take
    # away the TMPDIR its parent is still using.
    if os.getpid() != owner_pid:
        return
    try:
        os.unlink(path)
    except OSError:
        pass


def _short_tmpdir(real: str) -> str:
    """A short alias for `real`, or `real` itself if none can be made."""
    if os.name != "posix":
        return real
    directory = _alias_dir()
    if directory is None:
        return real
    # Named for the target, not the invocation: a run killed before its exit
    # hook leaves one entry, which its next run reuses instead of adding another.
    # fsencode, not encode: a path holding non-UTF-8 bytes reaches us as
    # surrogate escapes, which UTF-8 refuses to encode.
    link = os.path.join(directory, hashlib.sha256(os.fsencode(real)).hexdigest()[:16])
    try:
        os.symlink(real, link)
    except FileExistsError:
        # Left by another run of this target; reuse without taking ownership.
        # A still-live creator exiting first takes the alias with it.
        try:
            return link if os.readlink(link) == real else real
        except OSError:
            return real
    except OSError:
        return real
    atexit.register(_unlink_alias, link, os.getpid())
    return link


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

    TEST_TMPDIR is itself too deep to hold an AF_UNIX socket, whose address is
    capped at 104 bytes of sun_path (issues/1387) — `multiprocessing`'s spawn
    Manager binds one and dies with "AF_UNIX path too long". bind() measures the
    string it is handed, not the resolved path, so TMPDIR gets a short symlink
    and the files still land in TEST_TMPDIR.
    """
    if "TEST_TMPDIR" not in os.environ:
        return

    tmpdir = _short_tmpdir(os.path.abspath(os.environ["TEST_TMPDIR"]))
    for var in ("TMPDIR", "TMP", "TEMP"):
        os.environ[var] = tmpdir


def shard_info() -> tuple[int, int] | None:
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


def start_coverage() -> "Coverage | None":
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
    _absfile_mapping = {coverage.files.abs_file(mfe): mfe for mfe in manifest_entries}

    # Include patterns must be absolute: coveragepy matches relative patterns
    # against the CWD, so a test with `chdir` set would match nothing.
    cov = coverage.Coverage(include=list(_absfile_mapping.keys()))
    cov.start()
    return cov


def write_lcov(cov: "Coverage") -> None:
    """Stop `cov` and write Bazel's LCOV output file.

    https://bazel.build/configure/coverage
    """
    import coverage.exceptions

    cov.stop()
    output_file = os.getenv("COVERAGE_OUTPUT_FILE")
    assert output_file is not None

    unfixed = output_file + ".tmp"
    try:
        cov.lcov_report(outfile=unfixed)
    except coverage.exceptions.NoDataError as e:
        # An empty report must not fail an otherwise passing test.
        print("WARNING: no python coverage data collected:", e, file=sys.stderr)
        open(output_file, "w").close()
        return
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
