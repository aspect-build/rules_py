"""Snapshot rule that dumps the full venv tree structure for review diffs.

Produces a deterministic text file listing every symlink (with target)
and text file (with content) inside a ``py_venv`` target's output tree.
Used via ``write_source_files`` so changes to the venv assembly surface
as a reviewable diff.

The venv is transitioned to a fixed platform so interpreter repo names
and pyvenv.cfg contents are identical on every host.
"""

load("//py/private/py_venv:defs.bzl", "VirtualenvInfo")

def _snapshot_platform_transition_impl(_settings, _attr):
    return {
        "//command_line_option:platforms": "//py/private/py_venv/tests:snapshot_platform",
    }

_snapshot_platform_transition = transition(
    implementation = _snapshot_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _venv_tree_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".snap")
    venv = ctx.attr.venv[0]
    bin_python = venv[VirtualenvInfo].bin_python
    ctx.actions.run_shell(
        inputs = venv[DefaultInfo].default_runfiles.files,
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
            cfg = _snapshot_platform_transition,
            doc = "A `py_venv` target whose venv tree to snapshot.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
