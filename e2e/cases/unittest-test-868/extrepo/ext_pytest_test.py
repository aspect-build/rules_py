# Lives in an external repo (short_path ../test_driver_extrepo/...). If the
# driver dropped it, pytest would receive no collection paths and recurse the
# whole runfiles tree (see the unrelated failing test in this target's data).
def test_external_source_is_collected() -> None:
    assert True
