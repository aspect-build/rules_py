def test_root_scoped() -> None:
    # A py_pytest_test declared in the workspace-root package. Collection must
    # be scoped to this declared source, not the whole runfiles tree — see the
    # zzz_unrelated_fail_test.py data dep in BUILD.bazel.
    assert True
