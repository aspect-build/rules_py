# Supplied only as `data` to the external-src regression target. It is never in
# any target's srcs; if pytest ever collected it, the driver had fallen back to
# recursing the runfiles tree instead of scoping to the declared sources.
def test_unrelated_should_never_run() -> None:
    assert False, "pytest collected an unrelated data file — collection was not scoped"
