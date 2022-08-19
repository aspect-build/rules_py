PyWheelInfo = provider(
    doc = "Provides information about a Python Wheel",
    fields = {
        "files": "Depset of all files including deps for this wheel",
        "default_runfiles": "Runfiles of all files including deps for this wheel",
	"dependencies": "Depset of dependencies",
    },
)

PyVirtualInfo = provider(
    fields = {
        "dependencies": "Depset of dependencies"
    }
)
