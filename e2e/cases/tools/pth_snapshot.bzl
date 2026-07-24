"""Snapshot helpers: extract venv artifacts from a `py_venv` launcher."""

def _venv_root_shell(venv):
    """Shell fragment resolving `$venv` to the venv tree in the launcher's runfiles."""
    return """
            launcher=$(execpath {venv})
            runfiles="$$launcher".runfiles
            pkg=$$(dirname "$$launcher" | sed 's|^bazel-out/[^/]*/bin/||')
            vname=$$(basename "$$launcher")
            venv="$$runfiles/_main/$$pkg/.$$vname"
    """.format(venv = venv)

def extract_venv_tree(name, venv):
    """Snapshot the sorted top-level entries of a `py_venv` launcher's venv.

    Pins which prefix directories the venv materialises. A stock venv holds
    `bin/`, `lib/`, `pyvenv.cfg`; projecting wheel `.data/data/` files adds the
    prefix data roots (`share/`, `etc/`), so this gates that projection
    (https://github.com/aspect-build/rules_py/issues/1366) without depending on
    the wheels' file contents.
    """
    native.genrule(
        name = name,
        testonly = True,
        outs = [name],
        cmd = _venv_root_shell(venv) + """
            if [ ! -d "$$venv" ]; then
                echo "expected venv at $$venv, not found" >&2
                exit 1
            fi
            ls -1 "$$venv" | LC_ALL=C sort > $@
        """,
        tools = [venv],
        visibility = ["//:__pkg__"],
    )

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
