load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyVirtualInfo")

PYTHON_TOOLCHAIN_TYPE = "@rules_python//python:toolchain_type"

def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PYTHON_TOOLCHAIN_TYPE]
    
    install_dir = ctx.actions.declare_directory(
        "install",
    )

    # Options here:
    # 1. Use `uv pip install` which doesn't have isolated
    # 2. Use the Python toolchain and a downloaded pip wheel to run install
    # 3. Just unzip the damn thing
    #
    # We're going with #3 for now.
    #
    # Could probably use bsdtar here rather than non-hermetic unzip.

    # FIXME: Use bsdtar here
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]
    ctx.actions.run(
        executable = "/usr/bin/unzip",
        arguments = [
            # FIXME: What happens when this is a TreeArtifact?
            "-d", install_dir.path + "/site-packages",
            archive.path,
        ],
        inputs = [
            archive,
        ],
        outputs = [
            install_dir,
        ],
    )
    
    return [
        # FIXME: Need to generate PyInfo here
        DefaultInfo(
            files = depset([
                install_dir,
            ]),
            runfiles = ctx.runfiles(files = [
                install_dir,
            ])
        ),
        PyInfo(
            transitive_sources = depset([
                install_dir,
            ]),
            imports = depset([
                ctx.label.repo_name + "/install/site-packages",
            ]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
    ]


whl_install = rule(
    implementation = _whl_install,
    doc = """

""",
    attrs = {
        "src": attr.label(doc = ""),
    },
    toolchains = [
        PYTHON_TOOLCHAIN_TYPE,
    ],
    provides = [
        DefaultInfo,
        PyInfo,
    ]
)
