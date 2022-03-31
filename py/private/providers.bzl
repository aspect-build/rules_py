PyWheelInfo = provider(
    doc = "Provides information about a Python Wheel",
    fields = {
        "deps": "Depset of transitive wheel dependencies",
        "files": "Depset of all files including deps for this wheel",
    },
)

def make_py_wheel_info_from_filegroup(wheel_filegroup):
    files_depsets = []
    files_depsets.append(wheel_filegroup[DefaultInfo].files)
    files_depsets.append(wheel_filegroup[DefaultInfo].default_runfiles.files)

    return PyWheelInfo(
        deps = depset(transitive = wheels_depsets),
        files = wheel_filegroup[DefaultInfo].default_runfiles.files,
    )
