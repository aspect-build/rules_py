"""Snapshot helper: extract the `<venv_name>.pth` from a `py_venv` launcher."""

def extract_venv_pth(name, venv):
    """Copy the site-packages `.pth` out of a `py_venv` launcher's runfiles tree.

    The launcher binary is exposed via DefaultInfo; the venv tree (where the
    .pth lives) is only reachable through the launcher's runfiles. Using
    `tools = [venv]` makes Bazel materialise that runfiles tree in the sandbox.

    `name` doubles as the output filename — pick something that reads naturally
    as the snapshot source (e.g. `test_tool.venv.pth`).
    """
    native.genrule(
        name = name,
        testonly = True,
        outs = [name],
        cmd = """
            launcher=$(execpath {venv})
            runfiles="$$launcher".runfiles
            pkg=$$(dirname "$$launcher" | sed 's|^bazel-out/[^/]*/bin/||')
            vname=$$(basename "$$launcher")
            pth=$$(echo "$$runfiles/_main/$$pkg/.$$vname"/lib/python*/site-packages/"$$vname".pth)
            if [ ! -f "$$pth" ]; then
                echo "expected .pth at $$pth, not found" >&2
                ls -la "$$runfiles/_main/$$pkg/" 2>&1 >&2
                exit 1
            fi
            cp "$$pth" $@
        """.format(venv = venv),
        tools = [venv],
        visibility = ["//:__pkg__"],
    )
