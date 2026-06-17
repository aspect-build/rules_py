"""Private providers for PEP 517 wheel builds."""

BuiltWheelMetadataInfo = provider(
    doc = "Analysis-time metadata for the wheel produced from an sdist.",
    fields = {
        "console_scripts": "tuple[str] of console entry points encoded as name=module:func.",
        "directory_top_levels": "tuple[str] containing the directory subset of top_levels.",
        "top_levels": "tuple[str] containing every immediate site-packages entry.",
    },
)
