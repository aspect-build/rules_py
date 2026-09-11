"""Compile Python sources into PEP 552 unchecked-hash bytecode.

Usage: pyc_compile.py [--expect-version VERSION] [@ARGFILE] SRC PYCACHE DFILE...
       pyc_compile.py --persistent_worker

Each ``SRC PYCACHE DFILE`` triple compiles ``SRC`` to ``PYCACHE`` with
``DFILE`` stored as its logical source path. As a Bazel persistent worker the
same arguments arrive per request on stdin. Imports stay minimal: without a
worker the interpreter is spawned once per source, so module loading dominates.
"""

import importlib.util
import marshal
import sys

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}


class CompileError(Exception):
    pass


def parse_args(argv: list[str]) -> tuple[str | None, list[str]]:
    expect_version = None
    files = []
    args = iter(argv)
    for arg in args:
        if arg.startswith("@"):
            with open(arg[1:]) as f:
                expect_from_file, files_from_file = parse_args(f.read().splitlines())
                files += files_from_file
                expect_version = expect_from_file or expect_version
        elif arg == "--expect-version":
            expect_version = next(args, None)
        elif arg.startswith("--expect-version="):
            expect_version = arg.partition("=")[2]
        else:
            files.append(arg)
    return expect_version, files


def check_version(expected: str) -> None:
    actual = "{}.{}.{}".format(*sys.version_info[:3])
    if sys.version_info.releaselevel != "final":
        actual += _PRERELEASE_ABBREVS.get(
            sys.version_info.releaselevel, sys.version_info.releaselevel
        ) + str(sys.version_info.serial)
    # Bytecode magic is stable within a stable feature release but may change
    # between prereleases: full equality is required when either side is a
    # prerelease, otherwise major.minor must match.
    prerelease = (
        sys.version_info.releaselevel != "final"
        or not expected.replace(".", "").isdigit()
    )
    if actual.split(".")[:2] != expected.split(".")[:2] or (
        prerelease and actual != expected
    ):
        raise CompileError(
            "pyc compiler is Python {}, expected {}: emitted bytecode would "
            "not match the target runtime".format(actual, expected)
        )


def compile_all(argv: list[str]) -> None:
    expect_version, files = parse_args(argv)
    if not files or len(files) % 3:
        raise CompileError("expected SRC PYCACHE DFILE triples")
    if expect_version:
        check_version(expect_version)
    for src, pycache, dfile in zip(*[iter(files)] * 3):
        with open(src, "rb") as f:
            source = f.read()
        try:
            code = compile(source, dfile, "exec", dont_inherit=True, optimize=0)
        except SyntaxError as exc:
            raise CompileError("{}: {}".format(dfile, exc)) from exc
        # PEP 552 unchecked hash-based pyc: magic, flags=1, source hash, code.
        with open(pycache, "wb") as f:
            f.write(importlib.util.MAGIC_NUMBER)
            f.write((1).to_bytes(4, "little"))
            f.write(importlib.util.source_hash(source))
            f.write(marshal.dumps(code))


def worker_loop() -> None:
    """Serve Bazel JSON work requests, one per line on stdin, sequentially."""
    import json

    for line in sys.stdin:
        request = json.loads(line)
        if request.get("cancel"):
            continue
        response = {
            "exitCode": 0,
            "output": "",
            "requestId": request.get("requestId", 0),
        }
        try:
            compile_all(request["arguments"])
        except CompileError as exc:
            response.update(exitCode=1, output=str(exc))
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


def main() -> None:
    if sys.argv[1:] == ["--persistent_worker"]:
        worker_loop()
        return
    try:
        compile_all(sys.argv[1:])
    except CompileError as exc:
        sys.exit(str(exc))


main()
