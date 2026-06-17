"""quasi-public types."""

VirtualenvInfo = provider(
    doc = """Provider emitted by `py_venv` identifying a materialised
virtualenv for downstream consumers.

Consumed by `py_binary` / `py_test` when `expose_venv = True` splits
the call into a sibling py_venv + a binary that consumes it. The
binary's launcher exec's `runtime_python`; `imports` and
`wheels` are used for analysis-time coverage checks so binaries fail
loudly when their dep closure isn't covered by the venv.
""",
    fields = {
        "bin_python": "File — the venv's user-facing executable bin/python.",
        "runtime_python": "File — runfiles-aware interpreter used by binary launchers.",
        "venv_name": "str — the venv dir's basename (e.g. `.myapp_venv`). Combine with ctx.label to derive the runfiles path to the venv root.",
        "imports": "depset[str] — rlocation-root-relative import paths covered by this venv. Mirrors `PyInfo.imports` of the venv's dep closure. Used by py_binary to verify its own imports are a subset.",
        "wheels": "depset[struct] — per-wheel metadata (same shape as `PyWheelsInfo.wheels`). Used by py_binary to verify its own wheel deps are covered by the venv.",
        "transitive_sources": "depset[File] — first-party Python sources carried by this venv (its own `srcs` plus those of any `deps` that emit `PyInfo`). Surfaced by py_binary as `PyInfo.transitive_sources` so downstream consumers see the same source closure they'd see if srcs/deps lived on the binary directly.",
    },
)
