"""quasi-public types."""

PyExecutableInfo = provider(
    doc = "Provider emitted by `py_venv_exec` carrying launcher-level metadata that downstream consumers can't infer from the binary itself.",
    fields = {
        "entrypoint": "File — the `main` Python file the launcher exec's. Consumers convert to a runfiles path via `to_rlocation_path` at their own analysis time (e.g. `py_pex_binary` uses it to set the pex entrypoint without scraping the launcher).",
    },
)

VirtualenvInfo = provider(
    doc = """Provider emitted by `py_venv` identifying a materialised
virtualenv for downstream consumers.

Consumed by `py_binary` / `py_test` when `expose_venv = True` splits
the call into a sibling py_venv + a binary that consumes it. The
binary's launcher exec's the venv's `bin_python`; `imports` and
`wheels` are used for analysis-time coverage checks so binaries fail
loudly when their dep closure isn't covered by the venv.
""",
    fields = {
        "bin_python": "File — the venv's bin/python symlink. Callers needing a launcher target point here.",
        "venv_name": "str — the venv dir's basename (e.g. `.myapp_venv`). Combine with ctx.label to derive the runfiles path to the venv root.",
        "imports": "depset[str] — rlocation-root-relative import paths covered by this venv. Mirrors `PyInfo.imports` of the venv's dep closure. Used by py_binary to verify its own imports are a subset.",
        "wheels": "depset[struct] — per-wheel metadata (same shape as `PyWheelsInfo.wheels`). Used by py_binary to verify its own wheel deps are covered by the venv.",
        "transitive_sources": "depset[File] — first-party Python sources carried by this venv (its own `srcs` plus those of any `deps` that emit `PyInfo`). Surfaced by py_binary as `PyInfo.transitive_sources` so downstream consumers see the same source closure they'd see if srcs/deps lived on the binary directly.",
    },
)
