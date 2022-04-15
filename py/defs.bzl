"Public API re-exports"

load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_binary.bzl", _py_binary = "py_binary", _py_test = "py_test")

def py_library(name, **kwargs):
    _py_library(
        name = name,
        imports = kwargs.pop("imports", []) + ["."],
        **kwargs
    )

def py_binary(name, srcs = [], main = None, **kwargs):
    _py_binary(
        name = name,
        srcs = srcs,
        main = main if main != None else srcs[0],
        imports = kwargs.pop("imports", []) + ["."],
        **kwargs
    )

    native.filegroup(
        name = "%s_create_venv_files" % name,
        srcs = [name],
        tags = ["manual"],
        output_group = "create_venv",
    )

    native.sh_binary(
        name = "%s.venv" % name,
        tags = ["manual"],
        srcs = [":%s_create_venv_files" % name],
    )

def py_test(name, main = None, srcs = [], **kwargs):
    _py_test(
        name = name,
        srcs = srcs,
        main = main if main != None else srcs[0],
        imports = kwargs.pop("imports", []) + ["."],
        **kwargs
    )
