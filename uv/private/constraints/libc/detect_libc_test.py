#!/usr/bin/env python3
"""Unit tests for the libc detection heuristics in defs.bzl.

The `detect_libc()` function in uv/private/constraints/libc/defs.bzl is
Starlark and cannot be imported directly. This file tests a Python mirror
of the same branching logic using a minimal mock of repository_ctx.
Keep the `detect_libc` function below in sync with the Starlark original.
"""


class _ExecResult:
    """Stand-in for the struct returned by repository_ctx.execute()."""

    def __init__(self, return_code=0, stdout="", stderr=""):
        self.return_code = return_code
        self.stdout = stdout
        self.stderr = stderr


class _FakeCtx:
    """Minimal mock of repository_ctx that stubs out execute()."""

    def __init__(self, responses):
        # responses maps tuple(cmd) -> _ExecResult
        self._responses = {tuple(k): v for k, v in responses.items()}

    def execute(self, cmd):
        return self._responses.get(tuple(cmd), _ExecResult(return_code=1))


def detect_libc(repository_ctx):
    """Python mirror of detect_libc() from uv/private/constraints/libc/defs.bzl."""
    ldd_result = repository_ctx.execute(["ldd", "--version"])
    if ldd_result.return_code == 0:
        output = (ldd_result.stdout + ldd_result.stderr).lower()
        if "musl" in output:
            return "musl"
        elif "gnu" in output or "glibc" in output:
            return "glibc"

    musl_check = repository_ctx.execute(["which", "ld-musl-$(uname -m).so.1"])
    if musl_check.return_code == 0:
        return "musl"

    os_release = repository_ctx.execute(["cat", "/etc/os-release"])
    if os_release.return_code == 0:
        if "alpine" in os_release.stdout.lower():
            return "musl"

    return "unknown"


def test_ldd_stdout_musl():
    ctx = _FakeCtx({("ldd", "--version"): _ExecResult(stdout="musl libc (x86_64)\nVersion 1.2.3")})
    assert detect_libc(ctx) == "musl"


def test_ldd_stderr_musl():
    ctx = _FakeCtx({("ldd", "--version"): _ExecResult(stderr="musl libc 1.2")})
    assert detect_libc(ctx) == "musl"


def test_ldd_gnu_libc():
    ctx = _FakeCtx({("ldd", "--version"): _ExecResult(stdout="ldd (GNU libc) 2.39")})
    assert detect_libc(ctx) == "glibc"


def test_ldd_glibc_keyword():
    ctx = _FakeCtx({("ldd", "--version"): _ExecResult(stdout="glibc 2.17")})
    assert detect_libc(ctx) == "glibc"


def test_ldd_fails_alpine_os_release():
    ctx = _FakeCtx({
        ("ldd", "--version"): _ExecResult(return_code=1),
        ("which", "ld-musl-$(uname -m).so.1"): _ExecResult(return_code=1),
        ("cat", "/etc/os-release"): _ExecResult(stdout='NAME="Alpine Linux"\nID=alpine\n'),
    })
    assert detect_libc(ctx) == "musl"


def test_ldd_fails_non_alpine_os_release():
    ctx = _FakeCtx({
        ("ldd", "--version"): _ExecResult(return_code=1),
        ("which", "ld-musl-$(uname -m).so.1"): _ExecResult(return_code=1),
        ("cat", "/etc/os-release"): _ExecResult(stdout='NAME="Ubuntu"\nID=ubuntu\n'),
    })
    assert detect_libc(ctx) == "unknown"


def test_all_heuristics_fail():
    ctx = _FakeCtx({})
    assert detect_libc(ctx) == "unknown"


def test_ldd_output_case_insensitive():
    ctx = _FakeCtx({("ldd", "--version"): _ExecResult(stdout="GNU C Library 2.35")})
    assert detect_libc(ctx) == "glibc"


if __name__ == "__main__":
    import sys

    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
            passed += 1
        except Exception as e:
            print(f"FAIL {name}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
