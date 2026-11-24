"""Tests for marker_simplify.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":marker_simplify.bzl", "conflict_group_extra", "conflict_group_extras", "is_extra_only_marker", "simplify_conflict_markers", "simplify_extra_marker", "simplify_markers_for_extras")

# Markers as `uv lock` writes them for a project `conflict-repro` whose groups
# `cpu` and `cuda` conflict, each with its own torch index.
_CPU = "group-14-conflict-repro-cpu"
_CUDA = "group-14-conflict-repro-cuda"
_TORCH_DARWIN = "(sys_platform == 'darwin' and extra == '{cpu}') or (extra == '{cpu}' and extra == '{cuda}')".format(cpu = _CPU, cuda = _CUDA)
_TORCH_CPU = "(sys_platform != 'darwin' and extra == '{cpu}') or (extra == '{cpu}' and extra == '{cuda}')".format(cpu = _CPU, cuda = _CUDA)
_TORCH_PYPI = "(extra != '{cpu}' and extra != '{cuda}') or (extra == '{cpu}' and extra == '{cuda}')".format(cpu = _CPU, cuda = _CUDA)
_TORCH_CU129 = "extra == '{cuda}'".format(cuda = _CUDA)
_LABELS = {_CPU: 1, _CUDA: 1}
_CPU_ROUTING = struct(extra = _CPU, labels = _LABELS)
_CUDA_ROUTING = struct(extra = _CUDA, labels = _LABELS)


def _simplify_extra_marker_test_impl(ctx):
    env = unittest.begin(ctx)

    # Markers that don't reference `extra` pass through untouched.
    asserts.equals(env, "", simplify_extra_marker("", ["build"]))
    asserts.equals(env, "sys_platform == 'win32'", simplify_extra_marker("sys_platform == 'win32'", ["build"]))

    # Extra-only markers collapse to true ("") or false (None).
    asserts.equals(env, "", simplify_extra_marker("extra == 'build'", ["build"]))
    asserts.equals(env, "", simplify_extra_marker("extra == 'build'", ["other", "build"]))
    asserts.equals(env, "", simplify_extra_marker("extra != 'build'", ["other"]))
    asserts.equals(env, None, simplify_extra_marker("extra == 'build'", ["other"]))
    asserts.equals(env, None, simplify_extra_marker("extra == 'build'", []))

    # Mixed markers reduce to their platform residual. Residuals are re-rendered
    # by the evaluator with normalized (double) quoting.
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' and sys_platform == 'win32'", ["build"]))
    asserts.equals(env, None, simplify_extra_marker("extra == 'build' and sys_platform == 'win32'", ["other"]))
    asserts.equals(env, "", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", ["build"]))
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", ["other"]))

    # Identical residuals from several active extras are deduplicated.
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", ["a", "b"]))

    # Distinct residuals are joined under `or`.
    asserts.equals(
        env,
        "((sys_platform == \"win32\")) or ((os_name == \"nt\"))",
        simplify_extra_marker("(extra == 'a' and sys_platform == 'win32') or (extra == 'b' and os_name == 'nt')", ["a", "b"]),
    )

    return unittest.end(env)

simplify_extra_marker_test = unittest.make(
    _simplify_extra_marker_test_impl,
)

def _simplify_markers_for_extras_test_impl(ctx):
    env = unittest.begin(ctx)

    # True markers collapse to the unconditional "" marker; untouched markers
    # keep their original spelling.
    asserts.equals(
        env,
        {"": 1, "sys_platform == 'win32'": 1},
        simplify_markers_for_extras({"extra == 'build'": 1, "sys_platform == 'win32'": 1}, ["build"]),
    )

    # False markers are dropped; all-false collections become empty.
    asserts.equals(
        env,
        {},
        simplify_markers_for_extras({"extra == 'build'": 1}, ["other"]),
    )

    return unittest.end(env)

simplify_markers_for_extras_test = unittest.make(
    _simplify_markers_for_extras_test_impl,
)

def _is_extra_only_marker_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, is_extra_only_marker("extra == 'build'"))
    asserts.true(env, is_extra_only_marker("'build' == extra"))
    asserts.true(env, is_extra_only_marker("extra != 'build'"))

    # uv conflict-routing markers, including conjunctions.
    asserts.true(env, is_extra_only_marker("extra == 'group-9-project-dev'"))
    asserts.true(env, is_extra_only_marker("extra == 'a' and extra != 'b'"))
    asserts.true(env, is_extra_only_marker("(extra == 'a') or (extra == 'b')"))

    asserts.false(env, is_extra_only_marker(""))
    asserts.false(env, is_extra_only_marker("sys_platform == 'win32'"))
    asserts.false(env, is_extra_only_marker("extra == 'build' and sys_platform == 'win32'"))

    # "extra" appearing only inside a string literal doesn't qualify.
    asserts.false(env, is_extra_only_marker("platform_machine == 'extra'"))

    return unittest.end(env)

is_extra_only_marker_test = unittest.make(
    _is_extra_only_marker_test_impl,
)

def _conflict_group_extra_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, _CPU, conflict_group_extra("conflict-repro", "cpu"))

    # Both names are normalized the way uv normalizes them before counting.
    asserts.equals(env, "group-10-my-project-dev-gpu", conflict_group_extra("My_Project", "Dev.GPU"))
    asserts.equals(env, _CUDA, conflict_group_extra("conflict__repro", "CUDA"))

    project_data = {
        "project": {"name": "conflict-repro"},
        "dependency-groups": {"cpu": ["torch"], "cuda": ["torch"]},
    }
    conflicts = [[
        {"package": "conflict-repro", "group": "cpu"},
        {"package": "conflict-repro", "group": "cuda"},
    ]]
    asserts.equals(
        env,
        {"cpu": _CPU_ROUTING, "cuda": _CUDA_ROUTING},
        conflict_group_extras(project_data, {"conflicts": conflicts}),
    )

    # Without conflicts uv writes no routing markers, so there is nothing to decide.
    asserts.equals(env, {}, conflict_group_extras(project_data, {}))

    return unittest.end(env)

conflict_group_extra_test = unittest.make(
    _conflict_group_extra_test_impl,
)

def _simplify_conflict_markers_test_impl(ctx):
    env = unittest.begin(ctx)

    # The cpu group keeps its two CPU-index wheels, split by platform alone
    # (the evaluator keeps the residual term's own parentheses).
    asserts.equals(env, {"(sys_platform == \"darwin\")": 1}, simplify_conflict_markers({_TORCH_DARWIN: 1}, _CPU_ROUTING))
    asserts.equals(env, {"(sys_platform != \"darwin\")": 1}, simplify_conflict_markers({_TORCH_CPU: 1}, _CPU_ROUTING))
    asserts.equals(env, {}, simplify_conflict_markers({_TORCH_CU129: 1}, _CPU_ROUTING))
    asserts.equals(env, {}, simplify_conflict_markers({_TORCH_PYPI: 1}, _CPU_ROUTING))

    # The cuda group keeps only the cu129 wheel, unconditionally.
    asserts.equals(env, {}, simplify_conflict_markers({_TORCH_DARWIN: 1}, _CUDA_ROUTING))
    asserts.equals(env, {}, simplify_conflict_markers({_TORCH_CPU: 1}, _CUDA_ROUTING))
    asserts.equals(env, {"": 1}, simplify_conflict_markers({_TORCH_CU129: 1}, _CUDA_ROUTING))
    asserts.equals(env, {}, simplify_conflict_markers({_TORCH_PYPI: 1}, _CUDA_ROUTING))

    # A group outside every conflict set: `extra != ...` holds for the others.
    other = struct(extra = "group-14-conflict-repro-docs", labels = _LABELS)
    asserts.equals(env, {"": 1}, simplify_conflict_markers({_TORCH_PYPI: 1}, other))
    asserts.equals(env, {}, simplify_conflict_markers({_TORCH_CU129: 1}, other))

    # A marker that also names a package extra is not the group's to decide.
    mixed = "extra == 'cuda' and extra == '{}'".format(_CUDA)
    asserts.equals(env, {mixed: 1}, simplify_conflict_markers({mixed: 1}, _CPU_ROUTING))

    # Markers without conflict terms, and locks without conflicts, are untouched.
    asserts.equals(env, {"sys_platform == 'linux'": 1}, simplify_conflict_markers({"sys_platform == 'linux'": 1}, _CPU_ROUTING))
    asserts.equals(env, {"": 1}, simplify_conflict_markers({"": 1}, _CPU_ROUTING))
    asserts.equals(env, {_TORCH_CPU: 1}, simplify_conflict_markers({_TORCH_CPU: 1}, None))

    return unittest.end(env)

simplify_conflict_markers_test = unittest.make(
    _simplify_conflict_markers_test_impl,
)

def marker_simplify_test_suite():
    unittest.suite(
        "marker_simplify_tests",
        simplify_extra_marker_test,
        simplify_markers_for_extras_test,
        is_extra_only_marker_test,
        conflict_group_extra_test,
        simplify_conflict_markers_test,
    )
