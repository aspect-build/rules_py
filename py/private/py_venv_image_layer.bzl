"""py_venv_image_layer for creating container images with pre-built virtualenvs.

This is an alternative to py_image_layer that creates the virtualenv during the build
process rather than at container runtime. This allows cross-compilation from macOS to Linux.
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@tar.bzl//tar:mtree.bzl", "mtree_mutate", "mtree_spec")
load("@tar.bzl//tar:tar.bzl", "tar")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "VENV_TOOLCHAIN")

def _py_venv_image_layer_impl(ctx):
    """Implementation that creates a layer with a pre-built virtualenv."""

    # Get toolchains
    venv_toolchain = ctx.toolchains[VENV_TOOLCHAIN]
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN]

    # Get the binary and its runfiles
    binary = ctx.attr.binary
    binary_file = binary[DefaultInfo].files_to_run.executable
    runfiles = binary[DefaultInfo].default_runfiles

    # Create output directory for the pre-built venv
    venv_output = ctx.actions.declare_directory(ctx.attr.name + ".venv")

    # Collect all runfiles for the venv creation
    runfiles_list = runfiles.files.to_list()

    # Find the pth file in runfiles
    pth_file = None
    for f in runfiles_list:
        if f.basename.endswith(".pth") and "site-packages" not in f.path:
            pth_file = f
            break

    if not pth_file:
        fail("Could not find .pth file in binary runfiles")

    # Get Python interpreter path
    python_path = py_toolchain.python.path
    if py_toolchain.runfiles_interpreter:
        # Find python in runfiles
        for f in runfiles_list:
            if f.basename == "python3" or f.basename.startswith("python3."):
                if "bin" in f.path.split("/"):
                    python_path = f.path
                    break

    # Create the venv using the venv tool
    ctx.actions.run_shell(
        outputs = [venv_output],
        inputs = runfiles_list + [venv_toolchain.bin.bin],
        command = """
            set -e
            VENV_TOOL="{venv_tool}"
            PYTHON="{python}"
            PTH_FILE="{pth_file}"
            OUTPUT="{output}"
            VENV_NAME=".venv"
            
            # Create the venv
            "$VENV_TOOL" \
                --location "$OUTPUT" \
                --python "$PYTHON" \
                --pth-file "$PTH_FILE" \
                --collision-strategy "ignore" \
                --venv-name "$VENV_NAME"
            
            # Clean up unnecessary files to reduce image size
            find "$OUTPUT" -name "*.pyc" -delete 2>/dev/null || true
            find "$OUTPUT" -type d -name "__pycache__" -exec rm -rf {{}} + 2>/dev/null || true
            
            # Remove pip and other unnecessary packages from venv
            rm -rf "$OUTPUT/lib"*/python*/site-packages/pip* 2>/dev/null || true
            rm -rf "$OUTPUT/lib"*/python*/site-packages/setuptools* 2>/dev/null || true
            rm -rf "$OUTPUT/lib"*/python*/site-packages/wheel* 2>/dev/null || true
        """.format(
            venv_tool = venv_toolchain.bin.bin.path,
            python = python_path,
            pth_file = pth_file.path,
            output = venv_output.path,
        ),
        mnemonic = "PyVenvCreate",
        progress_message = "Creating virtualenv for %s" % ctx.attr.name,
    )

    # Create the manifest for the venv
    manifest = ctx.actions.declare_file(ctx.attr.name + ".manifest")
    ctx.actions.run_shell(
        outputs = [manifest],
        inputs = [venv_output],
        command = """
            # Generate mtree manifest from venv directory
            cd "$(dirname {venv})"
            find "$(basename {venv})" -type f -o -type l | while read f; do
                if [ -L "$f" ]; then
                    echo "$(echo $f | sed 's/^/{root}/') type=link link=$(readlink "$f")"
                else
                    echo "$(echo $f | sed 's/^/{root}/') type=file content={venv}/$f"
                fi
            done > {output}
        """.format(
            venv = venv_output.path,
            root = ctx.attr.root,
            output = manifest.path,
        ),
    )

    # Create the tar from the venv
    venv_tar = ctx.actions.declare_file(ctx.attr.name + ".tar.gz")
    ctx.actions.run_shell(
        outputs = [venv_tar],
        inputs = [venv_output, manifest],
        command = """
            tar -czf {output} -C $(dirname {venv}) $(basename {venv})
        """.format(
            venv = venv_output.path,
            output = venv_tar.path,
        ),
    )

    # Also include binary runfiles (excluding the venv tool)
    binary_manifest = ctx.actions.declare_file(ctx.attr.name + ".binary.manifest")

    # Use mtree_spec for the binary runfiles
    # Filter out venv-related files as they won't be needed

    return [
        DefaultInfo(
            files = depset([venv_tar]),
        ),
        OutputGroupInfo(
            venv = depset([venv_output]),
            tar = depset([venv_tar]),
        ),
    ]

py_venv_image_layer = rule(
    implementation = _py_venv_image_layer_impl,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "The py_binary target to include in the image",
        ),
        "root": attr.string(
            default = "/",
            doc = "Root path where the venv should be placed in the container",
        ),
    },
    toolchains = [
        VENV_TOOLCHAIN,
        PY_TOOLCHAIN,
    ],
)
