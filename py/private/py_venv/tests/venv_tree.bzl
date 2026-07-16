"""Snapshot rule that dumps the full venv tree structure for review diffs.

Produces a deterministic text file listing every symlink (with target)
and text file (with content) inside a ``py_venv`` target's output tree.
Used via ``write_source_files`` so changes to the venv assembly surface
as a reviewable diff.
"""

load("//py/private/py_venv:defs.bzl", "VirtualenvInfo")

def _venv_tree_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".snap")
    bin_python = ctx.attr.venv[VirtualenvInfo].bin_python
    ctx.actions.run_shell(
        inputs = ctx.attr.venv[VirtualenvInfo].all_files,
        outputs = [output],
        arguments = [output.path, bin_python.path],
        command = r"""
            set -e
            OUT="$(pwd)/$1"
            BIN_PYTHON="$2"
            ROOT="$(dirname "$(dirname "$BIN_PYTHON")")"
            cd "$ROOT"
            {
                find . | sort | while read p; do
                    if [ -L "$p" ]; then
                        target=$(readlink "$p")
                        case "$target" in
                            /*)
                                if [ -f "$p" ] && [ "$(wc -c < "$p")" -lt 8192 ]; then
                                    echo "FILE ${p#./}"
                                    echo "---"
                                    cat "$p"
                                    echo "---"
                                fi
                                ;;
                            *)
                                echo "LINK ${p#./} -> $target"
                                ;;
                        esac
                    elif [ -f "$p" ] && [ "$(wc -c < "$p")" -lt 8192 ]; then
                        echo "FILE ${p#./}"
                        echo "---"
                        cat "$p"
                        echo "---"
                    fi
                done
            } > "$OUT"
        """,
    )
    return DefaultInfo(files = depset([output]))

venv_tree = rule(
    implementation = _venv_tree_impl,
    attrs = {
        "venv": attr.label(
            providers = [VirtualenvInfo],
            mandatory = True,
            doc = "A `py_venv` target whose venv tree to snapshot.",
        ),
    },
)
