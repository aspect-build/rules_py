"""Unit tests for the exec-interpreter bytecode compatibility gate."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private:pyc.bzl", "bytecode_compatible", "pycache_tag")

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
    asserts.true(env, bytecode_compatible(_runtime(implementation_name = "pypy"), _runtime(implementation_name = "pypy")), "implementation matches")
    asserts.false(env, bytecode_compatible(_runtime(pyc_tag = "cpython-312"), _runtime(pyc_tag = "vendor-312")), "pyc tag differs")
    asserts.true(env, bytecode_compatible(
        _runtime(implementation_name = None, pyc_tag = "vendor-312"),
        _runtime(implementation_name = None, pyc_tag = "vendor-312"),
    ), "pyc tag matches without implementation")
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

    asserts.true(env, bytecode_compatible(struct(
        implementation_name = "cpython",
        interpreter_version_info = struct(major = 3, minor = 12),
    ), _runtime()), "sparse version_info")
    asserts.false(env, bytecode_compatible(struct(), _runtime()), "exec lacks version_info")
    asserts.false(env, bytecode_compatible(_runtime(), struct()), "target lacks version_info")

    asserts.equals(env, "vendor-312", pycache_tag(_runtime(pyc_tag = "vendor-312")), "explicit cache tag")
    asserts.equals(env, "pypy-312", pycache_tag(_runtime(implementation_name = "pypy")), "derived non-CPython cache tag")
    asserts.equals(env, None, pycache_tag(_runtime(implementation_name = None)), "unknown runtime cache tag")

    return unittest.end(env)

bytecode_compat_test = unittest.make(_bytecode_compat_test_impl)

def bytecode_compat_test_suite(name):
    unittest.suite(name, bytecode_compat_test)
