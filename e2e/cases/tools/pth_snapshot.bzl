"""Snapshot helpers: extract venv artifacts from a `py_venv` launcher."""

def extract_venv_data_tree(name, venv):
    """Snapshot the shape of a venv's PEP 427 prefix data projection.

    Emits one line per entry outside the venv-owned roots: `path/` for a real
    directory, `path -> target` for a symlink. That distinction *is* the
    projection rule — venv assembly binds a whole directory when one wheel owns
    everything beneath it and descends only where wheels share one, so a real
    directory marks a shared prefix path and an arrow marks a collapsed subtree
    (see `_collapse_data_projection`). Reverting the collapse turns a handful of
    lines into one per installed file.

    `find` is not given `-L`, so the walk stops at each symlink: the output ends
    exactly where the projection binds. `bin/`, `lib/` and `pyvenv.cfg` are
    pruned — no data file is ever projected into them, and they hold runfiles
    symlinks whose targets are absolute host paths.
    """
    native.genrule(
        name = name,
        testonly = True,
        outs = [name],
        # Only the prologue is `.format`ed: the loop below contains shell `${}`
        # expansions, which `.format` would read as replacement fields.
        cmd = """
            launcher=$(execpath {venv})
            runfiles="$$launcher".runfiles
            pkg=$$(dirname "$$launcher" | sed 's|^bazel-out/[^/]*/bin/||')
            vname=$$(basename "$$launcher")
            venv="$$runfiles/_main/$$pkg/.$$vname"
            if [ ! -d "$$venv" ]; then
                echo "expected venv at $$venv, not found" >&2
                exit 1
            fi
        """.format(venv = venv) + """
            find "$$venv" -mindepth 1 \
                \\( -path "$$venv/bin" -o -path "$$venv/lib" -o -path "$$venv/pyvenv.cfg" \\) \
                -prune -o -print \
            | while read -r entry; do
                relative=$${entry#"$$venv"/}
                if [ -L "$$entry" ]; then
                    echo "$$relative -> $$(readlink "$$entry")"
                else
                    echo "$$relative/"
                fi
            done | LC_ALL=C sort > $@
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
