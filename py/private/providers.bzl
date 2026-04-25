"""Providers to share information between targets in the graph."""

PyVirtualInfo = provider(
    doc = "FIXME",
    fields = {
        "dependencies": "Depset of required virtual dependencies, independent of their resolution status",
        "resolutions": "FIXME",
    },
)
