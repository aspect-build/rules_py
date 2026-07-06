"""quasi-public types."""

def venv_root(bin_python):
    """The venv root's runfiles-relative rootpath, derived from the
    `bin/python` symlink's short_path (drop the trailing `bin/python`).
    The value `py_venv` and its launcher export as `VIRTUAL_ENV`."""
    return bin_python.short_path.rsplit("/", 2)[0]

VirtualenvInfo = provider(
    doc = """Provider emitted by `py_venv` identifying a materialised
virtualenv for downstream consumers.

Consumed by `py_binary` / `py_test` when `expose_venv = True` splits
the call into a sibling py_venv + a binary that consumes it. The
binary's launcher exec's the venv's `bin_python`.
""",
    fields = {
        "bin_python": "File — the venv's bin/python symlink. Callers needing a launcher target point here.",
        "imports": "depset[str] — rlocation-root-relative import paths covered by this venv. Mirrors `PyInfo.imports` of the venv's dep closure.",
        "transitive_sources": "depset[File] — first-party Python sources carried by this venv (its own `srcs` plus those of any `deps` that emit `PyInfo`). Surfaced by py_binary as `PyInfo.transitive_sources` so downstream consumers see the same source closure they'd see if srcs/deps lived on the binary directly.",
    },
)
