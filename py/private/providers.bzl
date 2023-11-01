"Providers to share information between targets in the graph."

PyWheelInfo = provider(
    doc = "Provides information about a Python Wheel",
    fields = {
        "files": "Depset of all files including deps for this wheel",
        "default_runfiles": "Runfiles of all files including deps for this wheel",
    },
)

PyVirtualInfo = provider(
    doc = "FIXME",
    fields = {
        "dependencies": "Depset of required virtual dependencies, independant of their resolution status",
        "resolutions": "FIXME",
    },
)
