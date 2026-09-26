"""Unit tests for the exec-interpreter bytecode compatibility gate."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private:pyc.bzl", "bytecode_compatible", "bytecode_conflicts", "bytecode_key", "pycache_tag")

def _runtime(major = 3, minor = 12, micro = 4, releaselevel = "final", serial = 0, abi_flags = "", implementation_name = "cpython", pyc_tag = None):
    return struct(
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
    asserts.false(env, bytecode_compatible(_runtime(implementation_name = "pypy"), _runtime(implementation_name = "pypy")), "non-CPython releases share no bytecode identity")
    asserts.false(env, bytecode_compatible(_runtime(pyc_tag = "cpython-312"), _runtime(pyc_tag = "vendor-312")), "pyc tag differs")
    asserts.false(env, bytecode_compatible(
        _runtime(implementation_name = None, pyc_tag = "vendor-312"),
        _runtime(implementation_name = None, pyc_tag = "vendor-312"),
    ), "a matching non-CPython tag is not enough")
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
    asserts.false(env, bytecode_conflicts(other_minor, final, "pycache"), "pyc: distinct cache tags coexist")
    asserts.true(env, bytecode_conflicts(other_minor, final, "sourceless"), "pyc_only: one sourceless path per source")

    return unittest.end(env)

bytecode_conflicts_test = unittest.make(_bytecode_conflicts_test_impl)

def bytecode_compat_test_suite(name):
    unittest.suite(name, bytecode_compat_test, bytecode_conflicts_test)
