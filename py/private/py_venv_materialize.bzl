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
        pth_copy = '''
PYTHON_REWRITE="{python}"
PTH_ORIG="{pth}"
SITE_PKGS="$OUT/lib/python{major}.{minor}/site-packages"
$PYTHON_REWRITE -c "
import os, sys
pth_orig = os.path.abspath('$PTH_ORIG')
orig_dir = os.path.dirname(pth_orig)
sp = os.path.abspath('$SITE_PKGS')
with open(pth_orig) as f:
    lines = f.readlines()
with open(os.path.join(sp, os.path.basename(pth_orig)), 'w') as f:
    for line in lines:
        line = line.rstrip('\\n')
        if not line or line.startswith('#') or line.startswith('import'):
            f.write(line + '\\n')
            continue
        abs_path = os.path.normpath(os.path.join(orig_dir, line))
        rel_path = os.path.relpath(abs_path, sp)
        f.write(rel_path + '\\n')
"
'''.format(
            pth = pth_file.path,
            python = python_path,
            major = py_major,
            minor = py_minor,
        )

    # Generate a sitecustomize.py that adds runfiles paths to sys.path.
    # This works around UV --mode=bazel-runfiles generating .pth files with
    # relative paths that assume the venv is at the runfiles root.
    sitecustomize = """\
import json, os, sys

_runfiles_dir = os.environ.get("RUNFILES_DIR", "")
if not _runfiles_dir:
    # Fallback: derive from this file's location within the venv
    _site_packages = os.path.dirname(__file__)
    _venv_dir = os.path.dirname(os.path.dirname(os.path.dirname(_site_packages)))
    # Walk up looking for the runfiles root (contains whl_install repos)
    for _ in range(8):
        _venv_dir = os.path.dirname(_venv_dir)
        _test = os.path.join(_venv_dir, "aspect_rules_py++uv+whl_install__cosmos__cffi__2_0_0")
        if os.path.exists(_test):
            _runfiles_dir = _venv_dir
            break

_manifest_path = os.path.join(os.path.dirname(__file__), "pth_manifest.json")
if _runfiles_dir and os.path.exists(_manifest_path):
    with open(_manifest_path) as _f:
        _manifest = json.load(_f)
    for _entry in _manifest.get("entries", []):
        _repo = _entry.get("repo", "")
        _path = _entry.get("path", "")
        _full = os.path.join(_runfiles_dir, _repo, _path)
        if os.path.isdir(_full) and _full not in sys.path:
            sys.path.append(_full)
"""

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
export UV_CACHE_DIR="$(mktemp -d)"

"$UV" venv \
    --mode=bazel-runfiles \
    --pth-manifest="$MANIFEST" \
    --python="$PYTHON" \
    "$OUT"

{pth_copy}

# Copy manifest into site-packages so sitecustomize.py can read it
cp "$MANIFEST" "$OUT/lib/python{major}.{minor}/site-packages/pth_manifest.json"

# Write sitecustomize.py to fixup sys.path at interpreter startup
cat > "$OUT/lib/python{major}.{minor}/site-packages/sitecustomize.py" << 'PYEOF'
{sitecustomize}
PYEOF

tar -czf "$TAR" -C "$OUT" .
""".format(
            uv = uv.path,
            python = python_path,
            manifest = manifest_file.path,
            out = venv_dir.path,
            tar = venv_tar.path,
            pth_copy = pth_copy,
            major = py_major,
            minor = py_minor,
            sitecustomize = sitecustomize,
        ),
        progress_message = "Materializing venv for %s" % ctx.attr.name,
        execution_requirements = {"no-sandbox": "1"},
    )

    return [DefaultInfo(
        files = depset([venv_dir, venv_tar]),
        runfiles = ctx.runfiles(files = [venv_dir, venv_tar]),
    )]

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
