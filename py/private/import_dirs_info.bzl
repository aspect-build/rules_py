"""Execroot directories behind a target's import roots, for type checks.

Type checkers run in the execroot rather than in runfiles, so they need the
directories each import root occupies there, on every output root that holds a
target's files. rules_py rules return `ImportDirsInfo` next to their `PyInfo`;
for targets carrying only `@rules_python`'s `PyInfo`, an aspect on `deps`
computes it (see type_check/foreign_import_dirs.bzl).
"""

ImportDirsInfo = provider(
    doc = "Execroot directories behind a target's import roots, for type checks.",
    fields = {
        "import_dirs": "depset[str] — execroot-relative directories holding the files under `PyInfo.imports`. Each target contributes the directories its own import roots occupy on the output roots where it has files.",
        "pyi_import_dirs": "depset[str] — the same as `import_dirs`, for `PyInfo.pyi_imports`.",
    },
)

def get_import_dirs(target):
    """Execroot directories for the target's `imports`; empty when unknown."""
    if ImportDirsInfo in target:
        return target[ImportDirsInfo].import_dirs
    return depset()

def get_pyi_import_dirs(target):
    """Execroot directories for the target's `pyi_imports`; empty when unknown."""
    if ImportDirsInfo in target:
        return target[ImportDirsInfo].pyi_import_dirs
    return depset()
