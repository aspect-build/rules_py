"""Unit tests for the exec-interpreter bytecode compatibility gate."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private:pyc.bzl", "auto_shards", "bytecode_compatible", "bytecode_conflicts", "bytecode_key", "expected_version", "pycache_tag")

def _runtime(major = 3, minor = 12, micro = 4, releaselevel = "final", serial = 0, abi_flags = "", implementation_name = "cpython", pyc_tag = None, interpreter = None):
    return struct(
        interpreter = struct(path = interpreter) if interpreter else None,
        interpreter_version_info = struct(
            major = major,
            minor = minor,
            micro = micro,
            releaselevel = releaselevel,
            serial = serial,
        ),
        abi_flags = abi_flags,
        implementation_name = implementation_name,
        pyc_tag = pyc_tag,
    )

def _bytecode_compat_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, bytecode_compatible(_runtime(), _runtime()), "identical")
    asserts.true(env, bytecode_compatible(_runtime(micro = 3), _runtime(micro = 9)), "final micro differs")
    asserts.false(env, bytecode_compatible(_runtime(minor = 11), _runtime(minor = 12)), "minor differs")
    asserts.false(env, bytecode_compatible(_runtime(major = 2), _runtime()), "major differs")
    asserts.true(env, bytecode_compatible(_runtime(abi_flags = "t"), _runtime()), "ABI does not affect bytecode")
    asserts.false(env, bytecode_compatible(_runtime(), _runtime(implementation_name = "pypy")), "implementation differs")
    asserts.false(env, bytecode_compatible(_runtime(implementation_name = "pypy"), _runtime(implementation_name = "pypy")), "non-CPython without an interpreter identity")
    asserts.true(env, bytecode_compatible(_PYPY_7322, _PYPY_7322), "same non-CPython interpreter")
    asserts.false(env, bytecode_compatible(_PYPY_7322, _PYPY_7323), "non-CPython releases sharing a language version")
    asserts.false(env, bytecode_compatible(
        _runtime(implementation_name = "pypy", micro = 3, interpreter = "pypy/bin/pypy3"),
        _runtime(implementation_name = "pypy", micro = 4, interpreter = "pypy/bin/pypy3"),
    ), "non-CPython micro differs")
    asserts.false(env, bytecode_compatible(_runtime(pyc_tag = "cpython-312"), _runtime(pyc_tag = "vendor-312")), "pyc tag differs")
    asserts.false(env, bytecode_compatible(
        _runtime(implementation_name = None, pyc_tag = "vendor-312"),
        _runtime(implementation_name = None, pyc_tag = "vendor-312"),
    ), "a matching non-CPython tag is not an interpreter identity")
    asserts.true(env, bytecode_compatible(
        _runtime(implementation_name = None, pyc_tag = "vendor-312", interpreter = "vendor/bin/python"),
        _runtime(implementation_name = None, pyc_tag = "vendor-312", interpreter = "vendor/bin/python"),
    ), "matching non-CPython tag on the same interpreter")
    asserts.true(env, bytecode_compatible(
        _runtime(interpreter = "cpython_a/bin/python3"),
        _runtime(interpreter = "cpython_b/bin/python3"),
    ), "CPython ignores the interpreter artifact")
    asserts.true(env, bytecode_compatible(_runtime(pyc_tag = "cpython-312"), _runtime(pyc_tag = "cpython-312", implementation_name = None)), "CPython tag matches")
    asserts.false(env, bytecode_compatible(
        _runtime(implementation_name = None),
        _runtime(implementation_name = None),
    ), "runtime identity unknown")

    rc1 = _runtime(minor = 14, micro = 0, releaselevel = "candidate", serial = 1)
    rc2 = _runtime(minor = 14, micro = 0, releaselevel = "candidate", serial = 2)
    final = _runtime(minor = 14, micro = 0)
    asserts.true(env, bytecode_compatible(rc1, rc1), "same prerelease")
    asserts.false(env, bytecode_compatible(rc1, rc2), "prerelease serial differs")
    asserts.false(env, bytecode_compatible(rc1, final), "prerelease exec vs final target")
    asserts.false(env, bytecode_compatible(final, rc1), "final exec vs prerelease target")
    asserts.true(env, bytecode_compatible(rc1, _runtime(minor = 14, micro = None, releaselevel = "candidate", serial = 1)), "prerelease without micro")

    asserts.true(env, bytecode_compatible(struct(
        implementation_name = "cpython",
        interpreter_version_info = struct(major = 3, minor = 12),
    ), _runtime()), "sparse version_info")
    asserts.false(env, bytecode_compatible(struct(), _runtime()), "exec lacks version_info")
    asserts.false(env, bytecode_compatible(_runtime(), struct()), "target lacks version_info")

    asserts.equals(env, "vendor-312", pycache_tag(_runtime(pyc_tag = "vendor-312")), "explicit cache tag")
    asserts.equals(env, None, pycache_tag(_runtime(implementation_name = "pypy")), "undeclared cache tag is not guessed")

    return unittest.end(env)

bytecode_compat_test = unittest.make(_bytecode_compat_test_impl)

# PyPy 7.3.22 and 7.3.23 report the same language version and cache tag but use bytecode magic 416 and 432.
_PYPY_7322 = _runtime(minor = 11, micro = 15, implementation_name = "pypy", pyc_tag = "pypy311", interpreter = "external/pypy_7_3_22/bin/pypy3")
_PYPY_7323 = _runtime(minor = 11, micro = 15, implementation_name = "pypy", pyc_tag = "pypy311", interpreter = "external/pypy_7_3_23/bin/pypy3")

def _entry(runtime):
    return struct(
        pycache = struct(basename = "mod.{}.pyc".format(runtime.pyc_tag)),
        bytecode_key = bytecode_key(runtime),
    )

def _bytecode_conflicts_test_impl(ctx):
    env = unittest.begin(ctx)

    alpha = _entry(_runtime(minor = 13, micro = 0, releaselevel = "alpha", serial = 1, pyc_tag = "cpython-313"))
    final = _entry(_runtime(minor = 13, micro = 0, pyc_tag = "cpython-313"))
    later_final = _entry(_runtime(minor = 13, micro = 2, pyc_tag = "cpython-313"))
    other_minor = _entry(_runtime(minor = 12, pyc_tag = "cpython-312"))
    unknown = struct(pycache = final.pycache, bytecode_key = None)

    for mode in ["pycache", "sourceless"]:
        asserts.true(env, bytecode_conflicts(alpha, final, mode), mode + ": one cache tag, different magic")
        asserts.false(env, bytecode_conflicts(final, later_final, mode), mode + ": final micros share bytecode")
        asserts.true(env, bytecode_conflicts(unknown, final, mode), mode + ": unknown identity fails closed")
        asserts.true(env, bytecode_conflicts(_entry(_PYPY_7322), _entry(_PYPY_7323), mode), mode + ": non-CPython releases sharing a language version")
        asserts.false(env, bytecode_conflicts(_entry(_PYPY_7322), _entry(_PYPY_7322), mode), mode + ": same non-CPython interpreter")
    asserts.false(env, bytecode_conflicts(other_minor, final, "pycache"), "pyc: distinct cache tags coexist")
    asserts.true(env, bytecode_conflicts(other_minor, final, "sourceless"), "pyc_only: one sourceless path per source")

    return unittest.end(env)

bytecode_conflicts_test = unittest.make(_bytecode_conflicts_test_impl)

# Must match the version pyc_compile.py builds from sys.version_info.
def _expected_version_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "3.12.4", expected_version(_runtime()), "final")
    asserts.equals(env, "3.12.0", expected_version(_runtime(micro = None)), "final without micro")
    asserts.equals(env, "3.13.0a2", expected_version(_runtime(minor = 13, micro = 0, releaselevel = "alpha", serial = 2)), "alpha")
    asserts.equals(env, "3.13.0b1", expected_version(_runtime(minor = 13, micro = 0, releaselevel = "beta", serial = 1)), "beta")
    asserts.equals(env, "3.14.0rc1", expected_version(_runtime(minor = 14, micro = 0, releaselevel = "candidate", serial = 1)), "candidate")
    asserts.equals(env, "3.14.0rc0", expected_version(_runtime(minor = 14, micro = 0, releaselevel = "candidate", serial = None)), "candidate without serial")
    asserts.equals(env, None, expected_version(struct()), "unknown version")

    return unittest.end(env)

expected_version_test = unittest.make(_expected_version_test_impl)

def _auto_shards_test_impl(ctx):
    env = unittest.begin(ctx)

    for count, shards in [(0, 1), (1, 1), (64, 1), (65, 2), (128, 2), (129, 4), (256, 4), (257, 8)]:
        asserts.equals(env, shards, auto_shards(count), "{} sources".format(count))

    return unittest.end(env)

auto_shards_test = unittest.make(_auto_shards_test_impl)

def bytecode_compat_test_suite(name):
    unittest.suite(name, bytecode_compat_test, bytecode_conflicts_test, expected_version_test, auto_shards_test)
