"""quasi-public types."""

VirtualenvInfo = provider(
    doc = """Provider emitted by `py_venv` identifying a materialised
virtualenv for downstream consumers.

Consumed by `py_binary(external_venv = X)` to assemble its launcher against
an externally-provided venv. `bin_python` is what the launcher exec's;
`imports` and `wheels` are used for analysis-time coverage checks so
binaries fail loudly when their dep closure isn't covered by the venv.
""",
    fields = {
        "bin_python": "File — the venv's bin/python symlink. Callers needing a launcher target point here.",
        "venv_name": "str — the venv dir's basename (e.g. `.myapp_venv`). Combine with ctx.label to derive the runfiles path to the venv root.",
        "imports": "depset[str] — rlocation-root-relative import paths covered by this venv. Mirrors `PyInfo.imports` of the venv's dep closure. Used by py_binary to verify its own imports are a subset.",
        "wheels": "depset[struct] — per-wheel metadata (same shape as `PyWheelsInfo.wheels`). Used by py_binary to verify its own wheel deps are covered by the venv.",
    },
)
