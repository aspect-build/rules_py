"""Build rule that materializes a Python virtual environment for containers.

This rule takes a py_binary (typically platform-transitioned to Linux) and
produces a directory containing a fully materialized virtual environment.

The venv is created by running `uv venv --mode=bazel-runfiles` with a manifest
describing where each dependency lives in the Bazel runfiles tree.

Example:
    py_venv_materialize(
        name = "my_app_venv",
        binary = ":my_app.binary_linux",
    )
"""

load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load("//uv/private/toolchain:types.bzl", "UV_TOOLCHAIN")

def _py_venv_materialize_impl(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    py_major = py_toolchain.interpreter_version_info.major
    py_minor = py_toolchain.interpreter_version_info.minor

    venv_dir = ctx.actions.declare_directory(ctx.attr.name + ".venv")
    venv_tar = ctx.actions.declare_file(ctx.attr.name + ".venv.tar.gz")

    binary_runfiles = ctx.attr.binary[DefaultInfo].default_runfiles
    runfiles_files = binary_runfiles.files.to_list() if binary_runfiles else []

    repos = {}
    pth_file = None
    for f in runfiles_files:
        owner = f.owner
        if owner and "whl_install" in owner.repo_name:
            repos[owner.repo_name] = True
        if f.basename.endswith(".pth"):
            pth_file = f

    manifest_entries = []
    for repo_name in sorted(repos.keys()):
        manifest_entries.append({
            "repo": repo_name,
            "path": "install/lib/python{}.{}/site-packages".format(py_major, py_minor),
            "strategy": "pth",
        })

    manifest = {
        "repository": ctx.attr.repository,
        "python_version": "{}.{}".format(py_major, py_minor),
        "entries": manifest_entries,
    }

    manifest_file = ctx.actions.declare_file(ctx.attr.name + ".pth_manifest.json")
    ctx.actions.write(
        output = manifest_file,
        content = json.encode(manifest),
    )

    interpreter = py_toolchain.interpreter
    if interpreter:
        python_path = interpreter.path
    else:
        python_path = py_toolchain.interpreter_path

    uv = ctx.toolchains[UV_TOOLCHAIN].uvinfo.bin

    inputs = depset(
        direct = [manifest_file, uv],
        transitive = [
            depset(runfiles_files),
            py_toolchain.files,
        ],
    )

    pth_copy = ""
    if pth_file:
        pth_copy = 'cp "{pth}" "$OUT/lib/python{major}.{minor}/site-packages/"'.format(
            pth = pth_file.path,
            major = py_major,
            minor = py_minor,
        )

    ctx.actions.run_shell(
        outputs = [venv_dir, venv_tar],
        inputs = inputs,
        tools = [uv],
        command = """set -e
UV="{uv}"
PYTHON="{python}"
MANIFEST="{manifest}"
OUT="{out}"
TAR="{tar}"

"$UV" venv \
    --mode=bazel-runfiles \
    --pth-manifest="$MANIFEST" \
    --python="$PYTHON" \
    "$OUT"

{pth_copy}

tar -czf "$TAR" -C "$OUT" .
""".format(
            uv = uv.path,
            python = python_path,
            manifest = manifest_file.path,
            out = venv_dir.path,
            tar = venv_tar.path,
            pth_copy = pth_copy,
        ),
        progress_message = "Materializing venv for %s" % ctx.attr.name,
    )

    return [DefaultInfo(files = depset([venv_dir, venv_tar]))]

py_venv_materialize = rule(
    implementation = _py_venv_materialize_impl,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            doc = "The py_binary target (typically platform-transitioned) to materialize.",
        ),
        "repository": attr.string(
            default = "pypi",
            doc = "Repository name for the manifest.",
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UV_TOOLCHAIN,
    ],
)
