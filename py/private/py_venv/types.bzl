"""quasi-public types."""

VirtualenvInfo = provider(
    doc = """
    Provider used to distinguish venvs from py rules.
    """,
    fields = {
        "home": "Path of the virtualenv",
    },
)
