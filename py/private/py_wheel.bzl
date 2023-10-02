"Represent a python wheel file"

load("@bazel_skylib//lib:types.bzl", "types")
load("//py/private:providers.bzl", "PyWheelInfo")

_attrs = {
    "src": attr.label(
        doc = "The Wheel file, as defined by https://packaging.python.org/en/latest/specifications/binary-distribution-format/#binary-distribution-format",
        allow_single_file = [".whl"],
    ),
}

def _make_py_wheel_info(ctx, wheel_filegroups):
    if not types.is_list(wheel_filegroups):
        filegroups = [wheel_filegroups]
    else:
        filegroups = wheel_filegroups

    files_depsets = []
    runfiles = []
    for filegroup in filegroups:
        # The ordering is important here as we want to ensure we use the PyWheelInfo from transitive
        # py_library dependencies, and only fall back to DefaultInfo when translating from the wheel
        # filegroup to py_wheel_library
        if PyWheelInfo in filegroup:
            files_depsets.append(filegroup[PyWheelInfo].files)
            runfiles.append(filegroup[PyWheelInfo].default_runfiles)
        elif DefaultInfo in filegroup and not PyInfo in filegroup:
            # This is slightly incorrect, but we don't yet have a better way of knowing if the dependency is a filegroup
            # that we should consume a wheel from.
            # What we do know though is we must ignore other py_library dependencies from rules_python, so exclude anything
            # that provides the PyInfo provider.
            files_depsets.append(filegroup[DefaultInfo].files)
            files_depsets.append(filegroup[DefaultInfo].default_runfiles.files)
            runfiles.append(filegroup[DefaultInfo].default_runfiles)

    py_info_runfiles = ctx.runfiles()
    py_info_runfiles = py_info_runfiles.merge_all(runfiles)

    return PyWheelInfo(
        files = depset(transitive = files_depsets),
        default_runfiles = py_info_runfiles,
    )

def _py_wheel_impl(ctx):
    py_wheel_info = _make_py_wheel_info(ctx, ctx.attr.src)
    return [
        py_wheel_info,
    ]

py_wheel_lib = struct(
    implementation = _py_wheel_impl,
    attrs = _attrs,
    provides = [PyWheelInfo],
    make_py_wheel_info = _make_py_wheel_info,
)
