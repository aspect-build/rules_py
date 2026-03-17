"""Rule for pre-compiling .pyc bytecode from an installed wheel tree artifact."""

load("@rules_python//python:defs.bzl", "PyInfo")

# buildifier: disable=bzl-visibility
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _whl_compile_pyc(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime

    src_dir = ctx.attr.src[DefaultInfo].files.to_list()[0]
    install_dir = ctx.actions.declare_directory("install")

    ctx.actions.run(
        executable = py_toolchain.interpreter,
        arguments = [
            ctx.file._compile_script.path,
            src_dir.path,
            install_dir.path,
        ],
        inputs = depset(
            [src_dir, ctx.file._compile_script],
            transitive = [py_toolchain.files],
        ),
        outputs = [install_dir],
        mnemonic = "WhlCompilePyc",
        progress_message = "Pre-compiling .pyc for %s" % ctx.label.name,
    )

    # Forward PyInfo from the source, re-wrapping with the new tree artifact.
    src_pyinfo = ctx.attr.src[PyInfo]
    return [
        DefaultInfo(
            files = depset([install_dir]),
            runfiles = ctx.runfiles(files = [install_dir]),
        ),
        PyInfo(
            transitive_sources = depset([install_dir]),
            imports = src_pyinfo.imports,
            has_py2_only_sources = src_pyinfo.has_py2_only_sources,
            has_py3_only_sources = src_pyinfo.has_py3_only_sources,
            uses_shared_libraries = src_pyinfo.uses_shared_libraries,
        ),
    ]

whl_compile_pyc = rule(
    implementation = _whl_compile_pyc,
    doc = """Pre-compile .pyc bytecode from an installed wheel tree artifact.

Copies the input tree and runs compileall over it, producing a new tree
artifact with __pycache__/*.pyc files alongside the original .py sources.""",
    attrs = {
        "src": attr.label(
            mandatory = True,
            providers = [DefaultInfo, PyInfo],
            doc = "The installed wheel tree artifact to compile.",
        ),
        "_compile_script": attr.label(
            default = "//uv/private/pyc:compile_pyc.py",
            allow_single_file = True,
        ),
    },
    toolchains = [PY_TOOLCHAIN],
    provides = [DefaultInfo, PyInfo],
)
