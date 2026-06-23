"""Private providers for PEP 517 wheel builds."""

BuiltWheelMetadataInfo = provider(
    doc = "Analysis-time top-level layout and scripts for a wheel produced from an sdist.",
    fields = {
        "console_scripts": "Complete tuple[str] of console entry points encoded as name=module:func.",
        "directory_top_levels": "tuple[str] containing the directory subset of top_levels.",
        "origin": "Human-readable declaration origin used in execution-time mismatch diagnostics.",
        "top_levels": "Complete tuple[str] of immediate site-packages entries when nonempty.",
    },
)
