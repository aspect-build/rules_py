"""Provider for metadata discovered while configuring a source-built wheel."""

SourceBuiltWheelInfo = provider(
    doc = "Analysis-time metadata for a source-built wheel.",
    fields = {
        "console_scripts": "Complete tuple[str] encoded as name=module:object.",
    },
)
