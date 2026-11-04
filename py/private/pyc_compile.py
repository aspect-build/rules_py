"""Compile Python sources into PEP 552 hash-based bytecode.

Usage: pyc_compile.py [--expect-version VERSION] [--checked-hash] SRC OUT DFILE...
       pyc_compile.py @ARGFILE
       pyc_compile.py --persistent_worker

Each ``SRC OUT DFILE`` triple compiles ``SRC`` to ``OUT`` with ``DFILE`` stored
as its logical source path. ``--checked-hash`` makes Python re-validate the
bytecode against its source on import.
"""

from __future__ import annotations

import importlib.util
import marshal
import sys

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}


class CompileError(Exception):
    pass


def parse_args(argv: list[str]) -> tuple[str | None, bool, list[str]]:
    # Only a lone argument is an argfile: source paths may start with "@".
    if len(argv) == 1 and argv[0].startswith("@"):
        with open(argv[0][1:], encoding="utf-8") as f:
            argv = f.read().splitlines()
    expect_version = None
    checked_hash = False
    files = []
    args = iter(argv)
    for arg in args:
        if arg == "--expect-version":
            expect_version = next(args, None)
        elif arg == "--checked-hash":
            checked_hash = True
        else:
            files.append(arg)
    return expect_version, checked_hash, files


def check_version(expected: str) -> None:
    actual = "{}.{}.{}".format(*sys.version_info[:3])
    if sys.version_info.releaselevel != "final":
        actual += _PRERELEASE_ABBREVS.get(
            sys.version_info.releaselevel, sys.version_info.releaselevel
        ) + str(sys.version_info.serial)
    # Magic is stable within a final feature release but not across prereleases.
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
    expect_version, checked_hash, files = parse_args(argv)
    if not files or len(files) % 3:
        raise CompileError("expected SRC OUT DFILE triples")
    if expect_version:
        check_version(expect_version)
    for src, out, dfile in zip(*[iter(files)] * 3):
        write(out, compile_source(src, dfile, checked_hash))


def write(path: str, data: bytes) -> None:
    with open(path, "wb") as f:
        f.write(data)


def compile_source(src: str, dfile: str, checked_hash: bool) -> bytes:
    with open(src, "rb") as f:
        source = f.read()
    try:
        code = compile(source, dfile, "exec", dont_inherit=True, optimize=0)
    except SyntaxError as exc:
        import traceback

        raise CompileError("".join(traceback.format_exception_only(type(exc), exc)).rstrip()) from exc
    # PEP 552 hash-based pyc: magic, flags (bit 0 hash-based, bit 1 checked), source hash, code.
    return b"".join(
        [
            importlib.util.MAGIC_NUMBER,
            (3 if checked_hash else 1).to_bytes(4, "little"),
            importlib.util.source_hash(source),
            marshal.dumps(code),
        ]
    )


def worker_loop() -> None:
    """Serve Bazel JSON work requests, one per line on stdin, sequentially."""
    import json
    import warnings

    sys.stdin.reconfigure(encoding="utf-8")
    for line in sys.stdin:
        request = json.loads(line)
        if request.get("cancel"):
            continue
        response = {
            "exitCode": 0,
            "output": "",
            "requestId": request.get("requestId", 0),
        }
        # Compiler warnings would otherwise land in the worker log, unseen.
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            try:
                compile_all(request["arguments"])
            except CompileError as exc:
                response.update(exitCode=1, output=str(exc))
            except Exception:
                import traceback

                response.update(exitCode=1, output=traceback.format_exc())
        response["output"] = (
            "".join(
                [
                    warnings.formatwarning(
                        w.message, w.category, w.filename, w.lineno, w.line
                    )
                    for w in caught
                ]
            )
            + response["output"]
        )
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
