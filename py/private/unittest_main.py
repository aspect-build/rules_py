# -*- mode: python -*-
# Stdlib `unittest` driver entrypoint for `py_unittest_test`. Mirrors
# pytest_main.py's Bazel integrations (temp dir, coverage, sharding, JUnit XML,
# test filtering) but collects the declared source files with stdlib unittest.

import argparse
import importlib.machinery
import importlib.util
import os
import re
import sys
import time
import traceback
import unittest
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import TYPE_CHECKING, Any, Dict, Iterator, List, Literal, Optional
from xml.sax.saxutils import escape, quoteattr

# The closed set of JUnit outcomes the writer understands.
_Status = Literal["passed", "failure", "error", "skipped"]


@dataclass
class _Record:
    classname: str
    name: str
    time: float
    status: _Status
    message: str
    detail: str

if TYPE_CHECKING:
    from coverage import Coverage

# Point temp dirs at Bazel's per-test TEST_TMPDIR before anything resolves it
# (see the long rationale in pytest_main.py). Must run before the first
# tempfile.gettempdir(), which caches process-wide.
if "TEST_TMPDIR" in os.environ:
    for _tmp_env in ("TMPDIR", "TMP", "TEMP"):
        os.environ[_tmp_env] = os.environ["TEST_TMPDIR"]

# Coverage: Bazel hands us COVERAGE_MANIFEST when the target has
# InstrumentedFilesInfo. Same coveragepy symlink workaround as pytest_main.py.
cov: Optional["Coverage"] = None
coveragepy_absfile_mapping: Dict[str, str] = {}
if "COVERAGE_MANIFEST" in os.environ:
    try:
        import coverage
        import coverage.files

        with open(os.environ["COVERAGE_MANIFEST"]) as mf:
            manifest_entries = mf.read().splitlines()
            cov = coverage.Coverage(include=manifest_entries)
            coveragepy_absfile_mapping = {
                coverage.files.abs_file(mfe): mfe for mfe in manifest_entries
            }
        cov.start()
    except ModuleNotFoundError as e:
        print("WARNING: coverage requested but the 'coverage' package is not a dep", e)


def _import_test_modules(test_files: List[str]) -> List[ModuleType]:
    """Import each declared source file exactly once, under a module name
    derived from its full path.

    Loading the declared files directly (instead of `TestLoader().discover()`
    per directory) avoids two discovery hazards: nested roots re-running the
    same test, and same-basename files in sibling directories colliding
    (`discover()` imports by basename and raises ImportError). The dotted,
    path-derived module name keeps identities unique.
    """
    modules: List[ModuleType] = []
    for path in test_files:
        if not path.endswith(".py"):
            continue
        # Strip the leading ../ of external-repo runfiles paths so the derived
        # module name carries no leading dots; the original path still loads it.
        rel = path
        while rel.startswith("../"):
            rel = rel[len("../"):]
        mod_name = rel[:-len(".py")].replace("/", ".")
        loader = importlib.machinery.SourceFileLoader(mod_name, path)
        spec = importlib.util.spec_from_loader(mod_name, loader)
        if spec is None:
            raise ImportError("cannot load test module from %r" % path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[mod_name] = module
        loader.exec_module(module)
        modules.append(module)
    return modules


def _suite_from(loader: unittest.TestLoader, modules: List[ModuleType]) -> unittest.TestSuite:
    suite = unittest.TestSuite()
    for module in modules:
        suite.addTests(loader.loadTestsFromModule(module))
    return suite


def _iter_tests(suite: unittest.TestSuite) -> Iterator[unittest.TestCase]:
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _iter_tests(item)
        else:
            yield item


def _filter_by_substring(suite: unittest.TestSuite, needle: str) -> unittest.TestSuite:
    """Narrow a suite to tests whose dotted id contains `needle`. Used only for
    Bazel's --test_filter (TESTBRIDGE_TEST_ONLY), which ANDs with any native
    `-k` patterns already applied at load time."""
    matched = unittest.TestSuite()
    for test in _iter_tests(suite):
        if needle in test.id():
            matched.addTest(test)
    return matched


def _advertise_sharding() -> None:
    """Touch TEST_SHARD_STATUS_FILE up front so Bazel sees sharding support
    even if the run later exits early (empty discovery / no filter match).
    Otherwise Bazel masks the real error with 'the test runner did not
    advertise support for test sharding'."""
    status = os.environ.get("TEST_SHARD_STATUS_FILE")
    total = os.environ.get("TEST_TOTAL_SHARDS")
    if status and total and int(total) > 1:
        Path(status).touch()


def _shard(suite: unittest.TestSuite) -> unittest.TestSuite:
    """Keep every Nth test by stable-sorted id for Bazel sharding."""
    idx = os.environ.get("TEST_SHARD_INDEX")
    total = os.environ.get("TEST_TOTAL_SHARDS")
    if not (idx and total and int(total) > 1):
        return suite
    i, n = int(idx), int(total)
    sharded = unittest.TestSuite()
    for pos, test in enumerate(sorted(_iter_tests(suite), key=lambda t: t.id())):
        if pos % n == i:
            sharded.addTest(test)
    return sharded


# XML 1.0 forbids these code points even as escapes, so quoteattr/escape leave
# them in and ElementTree then rejects the file. Ordinary failure messages hit
# this (ANSI color escapes, an embedded NUL). Replace with U+FFFD, like pytest's
# bin_xml_escape.
_ILLEGAL_XML = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff\ufffe\uffff]")


def _xml_clean(text: str) -> str:
    return _ILLEGAL_XML.sub("\ufffd", text)


class _JUnitResult(unittest.TextTestResult):
    """TextTestResult that also records per-test outcomes and timing so we can
    emit Bazel-compatible JUnit XML with no third-party runner."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.records: List[_Record] = []
        self._start: Dict[unittest.TestCase, float] = {}

    def startTest(self, test: unittest.TestCase) -> None:
        self._start[test] = time.time()
        super().startTest(test)

    def _elapsed(self, test: unittest.TestCase) -> float:
        return time.time() - self._start.get(test, time.time())

    def _record(
        self,
        test: unittest.TestCase,
        status: _Status,
        err: Any = None,
        message: Optional[str] = None,
        name: Optional[str] = None,
    ) -> None:
        detail = ""
        if err is not None:
            detail = "".join(traceback.format_exception(err[0], err[1], err[2]))
            if message is None:
                message = str(err[1])
        self.records.append(_Record(
            classname=test.__class__.__module__ + "." + test.__class__.__qualname__,
            name=name or getattr(test, "_testMethodName", str(test)),
            time=self._elapsed(test),
            status=status,
            message=message or "",
            detail=detail,
        ))

    def addSuccess(self, test: unittest.TestCase) -> None:
        super().addSuccess(test)
        self._record(test, "passed")

    def addFailure(self, test: unittest.TestCase, err: Any) -> None:
        super().addFailure(test, err)
        self._record(test, "failure", err)

    def addError(self, test: unittest.TestCase, err: Any) -> None:
        super().addError(test, err)
        self._record(test, "error", err)

    def addSubTest(
        self,
        test: unittest.TestCase,
        subtest: unittest.TestCase,
        err: Any,
    ) -> None:
        super().addSubTest(test, subtest, err)
        # unittest only calls this per subtest that fails/errors (err set) — the
        # all-pass case reports one addSuccess on the parent. Without recording
        # the failing subtests here, wasSuccessful()/exit code would be correct
        # but the JUnit XML would show zero failures.
        if err is not None:
            status = "failure" if issubclass(err[0], test.failureException) else "error"
            # str(subtest) already includes the method name and subtest params.
            self._record(test, status, err, name=str(subtest))

    def addSkip(self, test: unittest.TestCase, reason: str) -> None:
        super().addSkip(test, reason)
        self._record(test, "skipped", message=reason)

    def addExpectedFailure(self, test: unittest.TestCase, err: Any) -> None:
        super().addExpectedFailure(test, err)
        self._record(test, "passed")

    def addUnexpectedSuccess(self, test: unittest.TestCase) -> None:
        super().addUnexpectedSuccess(test)
        self._record(test, "failure", message="unexpected success")


def _write_junit_xml(path: str, records: List[_Record], suite_name: str) -> None:
    failures = sum(1 for r in records if r.status == "failure")
    errors = sum(1 for r in records if r.status == "error")
    skipped = sum(1 for r in records if r.status == "skipped")
    total_time = sum(r.time for r in records)

    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<testsuites>"]
    lines.append(
        '  <testsuite name=%s tests="%d" failures="%d" errors="%d" skipped="%d" time="%.3f">'
        % (quoteattr(_xml_clean(suite_name)), len(records), failures, errors, skipped, total_time)
    )
    for r in records:
        # Every interpolated string is XML-cleaned: a subtest name derived from a
        # parameter whose repr emits control chars (e.g. an ANSI escape) would
        # otherwise write a byte ElementTree rejects.
        lines.append(
            '    <testcase classname=%s name=%s time="%.3f">'
            % (quoteattr(_xml_clean(r.classname)), quoteattr(_xml_clean(r.name)), r.time)
        )
        if r.status in ("failure", "error"):
            lines.append(
                "      <%s message=%s>%s</%s>"
                % (
                    r.status,
                    quoteattr(_xml_clean(r.message)),
                    escape(_xml_clean(r.detail)),
                    r.status,
                )
            )
        elif r.status == "skipped":
            lines.append("      <skipped message=%s/>" % quoteattr(_xml_clean(r.message)))
        lines.append("    </testcase>")
    lines += ["  </testsuite>", "</testsuites>"]

    # Declared UTF-8, so write UTF-8 regardless of the platform default encoding
    # (cp1252 on a Windows locale would otherwise UnicodeEncodeError on non-latin
    # text in a failure message).
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def _finalize_coverage() -> None:
    """Write Bazel's lcov output, applying the same SF:/FN: fixups as
    pytest_main.py (coveragepy #963, bazel #25118)."""
    assert cov is not None
    cov.stop()
    cov.save()

    out = os.environ.get("COVERAGE_OUTPUT_FILE")
    if not out:
        return

    unfixed = out + ".tmp"
    cov.lcov_report(outfile=unfixed)
    with open(unfixed) as src, open(out, "w") as dst:
        for line in src:
            # Undo coveragepy's symlink-following of source paths.
            if line.startswith("SF:"):
                sourcefile = line[3:].rstrip()
                if sourcefile in coveragepy_absfile_mapping:
                    dst.write("SF:%s\n" % coveragepy_absfile_mapping[sourcefile])
                    continue
            # Drop the 'end line number' from FN: records that Bazel rejects.
            if line.startswith("FN:"):
                parts = line[3:].split(",")
                if len(parts) == 3:
                    dst.write("FN:%s,%s" % (parts[0], parts[2]))
                    continue
            dst.write(line)
    os.unlink(unfixed)


def _parse_args(argv: List[str]) -> argparse.Namespace:
    """Parse the runtime args forwarded from the `args` attribute / command
    line. Errors (exit 2) on anything unrecognized rather than dropping it, so
    a typo'd flag is never silently ignored."""
    parser = argparse.ArgumentParser(
        prog="py_unittest_test",
        add_help=False,
        description="rules_py stdlib unittest driver",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="verbose output")
    parser.add_argument("-q", "--quiet", action="store_true", help="minimal output")
    parser.add_argument("-f", "--failfast", action="store_true", help="stop on first failure")
    parser.add_argument("-b", "--buffer", action="store_true", help="buffer stdout/stderr")
    parser.add_argument(
        "-k",
        dest="filters",
        action="append",
        default=[],
        metavar="PATTERN",
        help="only run tests matching PATTERN (native unittest -k; repeatable)",
    )
    return parser.parse_args(argv)


def main() -> int:
    os.environ["ENV"] = "testing"

    opts = _parse_args(sys.argv[1:])

    # Advertise sharding before any early return (see _advertise_sharding).
    _advertise_sharding()

    # The next assignment is rewritten at analysis time by py_unittest_test with
    # the target's own-repo source files. Keep it on its own line exactly as
    # written — the rule keys on the bare assignment text, so editing this
    # comment is safe but editing the code is not.
    test_files: List[str] = []

    modules = _import_test_modules(test_files)

    # Native unittest -k: patterns OR together and `*` is fnmatch; a pattern
    # with no wildcard is wrapped to a substring match, exactly as unittest's
    # own CLI does. Set on the loader so filtering happens during a SINGLE
    # loadTestsFromModule pass — collecting a second time would invoke each
    # module's load_tests(loader, tests, pattern) hook twice, and a stateful
    # hook could then hand the runner an empty suite (silently "Ran 0 tests").
    loader = unittest.TestLoader()
    if opts.filters:
        loader.testNamePatterns = [p if "*" in p else "*%s*" % p for p in opts.filters]
    suite = _suite_from(loader, modules)

    # Bazel's --test_filter narrows further (ANDed as a substring over the id).
    bazel_filter = os.environ.get("TESTBRIDGE_TEST_ONLY")
    if bazel_filter:
        suite = _filter_by_substring(suite, bazel_filter)

    # Emptiness is checked once, pre-shard, so a shard legitimately holding none
    # of the matching tests still passes. unittest would otherwise report
    # success on an empty run; fail loudly, matching pytest's exit-5.
    if suite.countTestCases() == 0:
        if opts.filters or bazel_filter:
            print(
                "ERROR: filter(s) matched no tests (-k=%r, --test_filter=%r)"
                % (opts.filters, bazel_filter),
                file=sys.stderr,
            )
        else:
            print(
                "ERROR: no tests found in %r" % (test_files,),
                file=sys.stderr,
            )
        return 1

    suite = _shard(suite)

    failfast = opts.failfast or os.environ.get("TESTBRIDGE_TEST_RUNNER_FAIL_FAST") == "1"

    # unittest verbosity: 0 quiet, 1 default, 2 verbose.
    if opts.quiet:
        verbosity = 0
    elif opts.verbose:
        verbosity = 2
    else:
        verbosity = 1

    # Record outcomes when Bazel asks for JUnit XML; the built-in writer below
    # needs no third-party runner.
    xml_out = os.environ.get("XML_OUTPUT_FILE")
    runner = unittest.TextTestRunner(
        verbosity=verbosity,
        failfast=failfast,
        buffer=opts.buffer,
        resultclass=_JUnitResult if xml_out else unittest.TextTestResult,
    )
    result = runner.run(suite)
    exit_code = 0 if result.wasSuccessful() else 1

    if xml_out and isinstance(result, _JUnitResult):
        _write_junit_xml(xml_out, result.records, os.environ.get("BAZEL_TARGET", "unittest"))

    if cov is not None and exit_code == 0:
        _finalize_coverage()

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
