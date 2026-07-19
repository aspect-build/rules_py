def test_unrelated_always_fails() -> None:
    # NOT in any target's srcs — only a `data` dep of root_scoped_test. If the
    # root-package pytest target recursed the runfiles tree instead of scoping
    # to its declared srcs, pytest would collect and run this, failing the
    # target. Named zzz_* so tree recursion would still reach it.
    assert False, "this unrelated test must never be collected"
