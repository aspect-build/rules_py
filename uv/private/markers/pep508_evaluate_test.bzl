"""Tests for pep508_evaluate.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "MARKER_ENV_ALIASES")
load(":pep508_evaluate.bzl", "evaluate", "tokenize")

_LINUX_ENV = {
    "implementation_name": "cpython",
    "implementation_version": "3.12.12",
    "os_name": "posix",
    "platform_machine": "x86_64",
    "platform_python_implementation": "CPython",
    "platform_release": "6.1.0",
    "platform_system": "Linux",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "linux",
}

_WINDOWS_ENV = {
    "implementation_name": "cpython",
    "os_name": "nt",
    "platform_machine": "x86_64",
    "platform_python_implementation": "CPython",
    "platform_release": "10",
    "platform_system": "Windows",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "win32",
}

_AARCH64_ENV = {
    "platform_machine": "aarch64",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "linux",
    "_aliases": MARKER_ENV_ALIASES,
}

_X86_64_ENV = {
    "platform_machine": "x86_64",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "linux",
    "_aliases": MARKER_ENV_ALIASES,
}

def _tokenize_test_impl(ctx):
    env = unittest.begin(ctx)

    # Empty / whitespace-only input
    asserts.equals(env, [], tokenize(""))
    asserts.equals(env, [], tokenize(" \t "))

    # Quoting is normalized to double quotes, for single- and double-quoted
    # values alike.
    asserts.equals(
        env,
        ["sys_platform", "==", "\"linux\""],
        tokenize("sys_platform == 'linux'"),
    )
    asserts.equals(
        env,
        ["os_name", "==", "\"nt\""],
        tokenize("os_name == \"nt\""),
    )

    # 'not' followed by 'in' fuses into a single "not in" token, regardless
    # of the whitespace between them.
    asserts.equals(
        env,
        ["\"win32\"", "not in", "sys_platform"],
        tokenize("'win32' not in sys_platform"),
    )
    asserts.equals(
        env,
        ["\"win32\"", "not in", "sys_platform"],
        tokenize("'win32'  not \t in  sys_platform"),
    )

    # Whitespace is trimmed: tabs, runs of spaces, and no spaces at all
    # around operators tokenize identically.
    expected = ["python_version", ">=", "\"3.10\""]
    asserts.equals(env, expected, tokenize("python_version >= '3.10'"))
    asserts.equals(env, expected, tokenize("python_version\t>=  '3.10'"))
    asserts.equals(env, expected, tokenize("python_version>='3.10'"))

    # Parentheses are standalone tokens, including when adjacent to
    # identifiers and quoted values.
    asserts.equals(
        env,
        ["(", "sys_platform", "==", "\"linux\"", ")"],
        tokenize("(sys_platform == 'linux')"),
    )
    asserts.equals(
        env,
        ["(", "(", "sys_platform", "==", "\"linux\"", ")", "and", "(", "os_name", "==", "\"posix\"", ")", ")"],
        tokenize("((sys_platform == 'linux') and (os_name == 'posix'))"),
    )

    return unittest.end(env)

tokenize_test = unittest.make(
    _tokenize_test_impl,
)

def _evaluate_test_impl(ctx):
    env = unittest.begin(ctx)

    # Simple equality on sys_platform
    asserts.true(env, evaluate("sys_platform == 'linux'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform == 'win32'", env = _LINUX_ENV))

    # Inequality
    asserts.true(env, evaluate("sys_platform != 'win32'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform != 'linux'", env = _LINUX_ENV))

    # 'in' operator
    asserts.true(env, evaluate("'linux' in sys_platform", env = _LINUX_ENV))
    asserts.false(env, evaluate("'linux' in sys_platform", env = _WINDOWS_ENV))

    # 'not in' operator
    asserts.true(env, evaluate("'win32' not in sys_platform", env = _LINUX_ENV))
    asserts.false(env, evaluate("'linux' not in sys_platform", env = _LINUX_ENV))

    # Version comparisons
    asserts.true(env, evaluate("python_version >= '3.10'", env = _LINUX_ENV))
    asserts.false(env, evaluate("python_version >= '3.12'", env = _LINUX_ENV))
    asserts.true(env, evaluate("python_full_version < '3.12.0'", env = _LINUX_ENV))
    asserts.false(env, evaluate("python_full_version < '3.10.0'", env = _LINUX_ENV))
    asserts.true(env, evaluate("implementation_version == '3.12.*'", env = _LINUX_ENV))
    asserts.false(env, evaluate("implementation_version != '3.12.*'", env = _LINUX_ENV))
    asserts.false(env, evaluate("implementation_version == '3.1.*'", env = _LINUX_ENV))
    asserts.true(env, evaluate("implementation_version != '3.11.*'", env = _LINUX_ENV))

    # Non-version string variables beyond sys_platform. These all evaluate via
    # _env_expr (string ==/!=/in/not in), so each is exercised in both the
    # active and inactive direction.
    asserts.true(env, evaluate("os_name == 'posix'", env = _LINUX_ENV))
    asserts.false(env, evaluate("os_name == 'nt'", env = _LINUX_ENV))
    asserts.true(env, evaluate("os_name == 'nt'", env = _WINDOWS_ENV))

    asserts.true(env, evaluate("platform_system == 'Linux'", env = _LINUX_ENV))
    asserts.false(env, evaluate("platform_system == 'Windows'", env = _LINUX_ENV))
    asserts.true(env, evaluate("platform_system == 'Windows'", env = _WINDOWS_ENV))

    asserts.true(env, evaluate("implementation_name == 'cpython'", env = _LINUX_ENV))
    asserts.false(env, evaluate("implementation_name == 'pypy'", env = _LINUX_ENV))
    asserts.true(env, evaluate("implementation_name != 'pypy'", env = _LINUX_ENV))

    asserts.true(env, evaluate("platform_python_implementation == 'CPython'", env = _LINUX_ENV))
    asserts.false(env, evaluate("platform_python_implementation == 'PyPy'", env = _LINUX_ENV))

    # platform_release is a NON-version variable (string compare), despite
    # looking version-like -- so '==' is exact-string, not semver matching.
    asserts.true(env, evaluate("platform_release == '6.1.0'", env = _LINUX_ENV))
    asserts.false(env, evaluate("platform_release == '6.1'", env = _LINUX_ENV))
    asserts.true(env, evaluate("'6.1' in platform_release", env = _LINUX_ENV))
    asserts.false(env, evaluate("'5.10' in platform_release", env = _LINUX_ENV))

    # 'and' / 'or' combinations
    asserts.true(env, evaluate("sys_platform == 'linux' and python_version >= '3.10'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform == 'linux' and python_version >= '3.12'", env = _LINUX_ENV))
    asserts.true(env, evaluate("sys_platform == 'win32' or sys_platform == 'linux'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform == 'win32' or sys_platform == 'darwin'", env = _LINUX_ENV))

    # 'not' operator
    asserts.true(env, evaluate("sys_platform != 'emscripten' and sys_platform != 'win32'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform != 'emscripten' and sys_platform != 'win32'", env = _WINDOWS_ENV))

    # Double-quoted values (PEP 508 allows both quote styles; uv locks
    # typically emit single quotes, so pin the other style explicitly).
    asserts.true(env, evaluate("os_name == \"nt\"", env = _WINDOWS_ENV))
    asserts.false(env, evaluate("os_name == \"nt\"", env = _LINUX_ENV))

    # Precedence: 'and' binds tighter than 'or'. Each pair distinguishes
    # correct grouping from the flat left-to-right reading.
    #
    # true or (false and false) == true; ((true or false) and false) == false.
    asserts.true(env, evaluate("sys_platform == 'linux' or sys_platform == 'win32' and python_version >= '3.12'", env = _LINUX_ENV))

    # (false and true) or true == true; (false and (true or true)) == false.
    asserts.true(env, evaluate("sys_platform == 'win32' and os_name == 'posix' or sys_platform == 'linux'", env = _LINUX_ENV))

    # Parentheses override the default precedence.
    asserts.false(env, evaluate("(sys_platform == 'linux' or sys_platform == 'win32') and python_version >= '3.12'", env = _LINUX_ENV))
    asserts.true(env, evaluate("sys_platform == 'linux' or (sys_platform == 'win32' and python_version >= '3.12')", env = _LINUX_ENV))

    # Unary 'not'
    asserts.true(env, evaluate("not sys_platform == 'win32'", env = _LINUX_ENV))
    asserts.false(env, evaluate("not sys_platform == 'linux'", env = _LINUX_ENV))
    asserts.true(env, evaluate("not not sys_platform == 'linux'", env = _LINUX_ENV))
    asserts.true(env, evaluate("not (sys_platform == 'win32' or sys_platform == 'darwin')", env = _LINUX_ENV))
    asserts.false(env, evaluate("not (sys_platform == 'win32' or sys_platform == 'linux')", env = _LINUX_ENV))

    # 'not' binds tighter than 'and'/'or'.
    asserts.true(env, evaluate("not sys_platform == 'win32' and python_version >= '3.10'", env = _LINUX_ENV))
    asserts.false(env, evaluate("not sys_platform == 'linux' and python_version >= '3.10'", env = _LINUX_ENV))
    asserts.true(env, evaluate("not sys_platform == 'linux' or python_version >= '3.10'", env = _LINUX_ENV))

    # Empty marker evaluates to True
    asserts.true(env, evaluate("", env = _LINUX_ENV))

    # Nested parentheses
    asserts.true(env, evaluate("((sys_platform == 'linux'))", env = _LINUX_ENV))
    asserts.true(env, evaluate("((sys_platform == 'linux') and (platform_machine == 'x86_64')) or sys_platform == 'win32'", env = _LINUX_ENV))

    # Identifier immediately followed by ')'
    asserts.true(env, evaluate("('linux' in sys_platform)", env = _LINUX_ENV))
    asserts.true(env, evaluate("('win32' not in sys_platform)", env = _LINUX_ENV))
    asserts.true(env, evaluate("(python_version >= '3.10' and 'linux' in sys_platform)", env = _LINUX_ENV))

    # Architecture alias normalization (decide_marker populates _aliases so
    # Python-spelled arch names match Bazel-spelled platform_machine values).
    asserts.true(env, evaluate("platform_machine == 'arm64'", env = _AARCH64_ENV))
    asserts.true(env, evaluate("platform_machine == 'ARM64'", env = _AARCH64_ENV))
    asserts.true(env, evaluate("'arm64' == platform_machine", env = _AARCH64_ENV))
    asserts.true(env, evaluate("platform_machine == 'aarch64'", env = _AARCH64_ENV))
    asserts.false(env, evaluate("platform_machine == 'arm64'", env = _X86_64_ENV))
    asserts.false(env, evaluate("platform_machine == 'ARM64'", env = _X86_64_ENV))
    asserts.true(env, evaluate("platform_machine == 'amd64'", env = _X86_64_ENV))
    asserts.true(env, evaluate("platform_machine == 'AMD64'", env = _X86_64_ENV))
    asserts.true(env, evaluate("platform_machine == 'x64'", env = _X86_64_ENV))
    asserts.true(env, evaluate("platform_machine != 'arm64'", env = _X86_64_ENV))

    return unittest.end(env)

evaluate_test = unittest.make(
    _evaluate_test_impl,
)

def _version_ops_test_impl(ctx):
    env = unittest.begin(ctx)

    # '~=' compatible release: >= right and < right.upper().
    asserts.true(env, evaluate("python_full_version ~= '3.11.0'", env = _LINUX_ENV))
    asserts.false(env, evaluate("python_full_version ~= '3.10.2'", env = _LINUX_ENV))
    asserts.false(env, evaluate("python_full_version ~= '3.12.0'", env = _LINUX_ENV))

    # Two-segment '~=' bumps the major for its upper bound (3.11 < 4.0).
    asserts.true(env, evaluate("python_version ~= '3.10'", env = _LINUX_ENV))
    asserts.false(env, evaluate("python_version ~= '3.12'", env = _LINUX_ENV))

    # Single-segment right side: upper bound is the next major.
    asserts.true(env, evaluate("python_version ~= '3'", env = _LINUX_ENV))

    version_env = dict(_LINUX_ENV)
    for candidate, spec, want in [
        # Arbitrary equality is case-insensitive but does not normalize.
        ("3.11.0", "=== '3.11.0'", True),
        ("3.11.0", "=== '3.11'", False),
        ("3.15.0a6", "=== '3.15.0A6'", True),
        ("3.15.0a6", "=== '3.15.0-alpha6'", False),
        ("legacy-build", "=== 'LEGACY-BUILD'", True),
        # Prereleases and their aliases use PEP 440 ordering.
        ("3.15.0a6", "== '3.15'", False),
        ("3.15.0a6", "!= '3.15'", True),
        ("3.15.0a6", ">= '3.15'", False),
        ("3.15.0a6", "<= '3.15'", True),
        ("3.15.0a6", "< '3.15'", False),
        ("3.15.0a6", "== '3.15.0alpha6'", True),
        ("3.15.0a6", "< '3.15.0beta1'", True),
        ("3.15.0a6", "< '3.15.0preview2'", True),
        ("3.15.0a1-dev10", "> '3.15.0a1_dev2'", True),
        ("3.15rc1.dev2", "> '3.15b9-dev9'", True),
        ("1.0b1.post1", "> '1.0a1'", True),
        ("1.0a2.post1", "> '1.0a1'", True),
        ("1.0a1.post1", "> '1.0a1'", False),
        ("1.0a1.post1", "> '1.0a1.dev1'", True),
        ("3.15.0.dev1", "< '3.15'", False),
        ("3.14.10.dev1", "~= '3.14.9'", True),
        # Post releases and nonzero extra release components admit the
        # prerelease below them; zero-padded finals do not.
        ("3.15a6", "< '3.15.0.0'", False),
        ("3.15.0.dev1", "< '3.15.0.0'", False),
        ("3.15.0rc1", "< '3.15.0.0'", False),
        ("3.15a6", "< '3.15.post0'", True),
        ("3.15.0.dev1", "< '3.15.post1'", True),
        ("3.15.0rc1", "< '3.15.0.post1'", True),
        ("3.15a6", "< '3.15.0.1'", True),
        ("3.15.post2", "> '3.15.post1'", True),
        ("3.15.post1", "> '3.15'", False),
        ("3.15.0.post1", "> '3.15'", False),
        # Local labels participate only when the equality bound has one.
        ("3.15.0+foo.01", "== '3.15.0+FOO-1'", True),
        ("3.15.0+foo.01", "!= '3.15.0+FOO-1'", False),
        ("3.15.0+bar", "== '3.15.0'", True),
        ("3.15.0+bar", "> '3.15.0'", False),
        ("3.15.0+bar", ">= '3.15.0'", True),
        ("3.15.0", "<= '3.15.0+bar'", False),
        ("3.15.0+bar", "<= '3.15.0+bar'", True),
        ("2!1.0", "== '1!1.*'", False),
        ("2!1.0", "!= '1!1.*'", True),
        ("1!1.0", "== '1!1.*'", True),
        ("1!1.0", "!= '1!1.*'", False),
        # Demonstrated non-PEP 440 interpreter values retain legacy ordering.
        ("3.15.0-dev.foo", "< '3.15.0-dev.foo.bar'", True),
        ("3.15.0-foo.1", "> '3.15.0-foo'", True),
        ("3.15.0-a.foo.10", "< '3.15.0-a.foo.dev.2'", True),
        ("3.15.0-a.1.dev.foo", "~= '3.14.9'", True),
    ]:
        version_env["python_full_version"] = candidate
        got = evaluate("python_full_version {}".format(spec), env = version_env)
        asserts.equals(env, want, got, "{} {}".format(candidate, spec))

    # Preserve reversed-operand dispatch, including invalid ordered-local
    # bounds whose raw spelling matches exactly.
    version_env["python_full_version"] = "3.15.0+bar"
    asserts.true(env, evaluate("'3.15.0+bar' <= python_full_version", env = version_env))
    asserts.true(env, evaluate("'3.15.0+bar' >= python_full_version", env = version_env))
    asserts.false(env, evaluate("'3.15.0' <= python_full_version", env = version_env))
    asserts.false(env, evaluate("'3.15.0' >= python_full_version", env = version_env))

    # A variable that is neither a known string var nor *_version evaluates
    # to False rather than failing, even when the values would match.
    weird_env = dict(_LINUX_ENV)
    weird_env["weird_var"] = "x"
    asserts.false(env, evaluate("weird_var == 'x'", env = weird_env))

    return unittest.end(env)

version_ops_test = unittest.make(
    _version_ops_test_impl,
)

def _partial_evaluate_test_impl(ctx):
    env = unittest.begin(ctx)

    # With strict = False an expression over env vars that are absent is
    # returned as a normalized string instead of failing.
    asserts.equals(env, 'extra == "tls"', evaluate("extra == 'tls'", env = {}, strict = False))

    # 'and': a True side reduces to the unknown side; a False side wins.
    asserts.equals(env, 'extra == "tls"', evaluate("sys_platform == 'linux' and extra == 'tls'", env = _LINUX_ENV, strict = False))
    asserts.equals(env, 'extra == "tls"', evaluate("extra == 'tls' and sys_platform == 'linux'", env = _LINUX_ENV, strict = False))
    asserts.false(env, evaluate("sys_platform == 'win32' and extra == 'tls'", env = _LINUX_ENV, strict = False))
    asserts.equals(env, 'extra == "a" and extra2 == "b"', evaluate("extra == 'a' and extra2 == 'b'", env = {}, strict = False))

    # 'or': a True side makes the unknown side irrelevant (empty string); a
    # False side reduces to the unknown side.
    asserts.equals(env, "", evaluate("extra == 'tls' or sys_platform == 'linux'", env = _LINUX_ENV, strict = False))
    asserts.equals(env, "", evaluate("sys_platform == 'linux' or extra == 'tls'", env = _LINUX_ENV, strict = False))
    asserts.equals(env, 'extra == "tls"', evaluate("extra == 'tls' or sys_platform == 'win32'", env = _LINUX_ENV, strict = False))
    asserts.equals(env, 'extra == "tls"', evaluate("sys_platform == 'win32' or extra == 'tls'", env = _LINUX_ENV, strict = False))
    asserts.equals(env, 'extra == "a" or extra2 == "b"', evaluate("extra == 'a' or extra2 == 'b'", env = {}, strict = False))

    # 'not' over an unknown expression is preserved as a string.
    asserts.equals(env, 'not extra == "tls"', evaluate("not extra == 'tls'", env = {}, strict = False))

    # Unknown expressions inside parentheses keep their grouping.
    asserts.equals(env, '(extra == "tls")', evaluate("(extra == 'tls') and sys_platform == 'linux'", env = _LINUX_ENV, strict = False))

    return unittest.end(env)

partial_evaluate_test = unittest.make(
    _partial_evaluate_test_impl,
)

def pep508_evaluate_test_suite():
    unittest.suite(
        "pep508_evaluate_tests",
        evaluate_test,
        partial_evaluate_test,
        tokenize_test,
        version_ops_test,
    )
