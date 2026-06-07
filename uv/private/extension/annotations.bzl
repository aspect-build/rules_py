"""Format spec and parser for `uv.unstable_annotate_packages()` files.

An annotations file is a TOML document that associates rules_py-specific
build metadata with packages resolved from a `uv.lock` file. The `uv.lock`
format has no standard way to express this data (see [1]), so annotations
are the workaround. Files are registered against a specific lockfile:

    uv.unstable_annotate_packages(
        src = "//:annotations.toml",
        lock = "//:uv.lock",
    )

## File format

    # Format version. Reserved; not currently validated.
    version = "0.0.0"

    [[package]]
    # Package name, resolved against the lockfile. Mandatory.
    name = "bravado-core"

    # Package version. Optional; when omitted the annotation applies to
    # the single version of the package in the lockfile. Entries that
    # don't resolve against this lockfile are ignored, so one annotation
    # file may be shared across several locks.
    version = "6.1.1"

    # Packages (resolved against the same lockfile) made available at
    # build time when this package is built from an sdist. Optional.
    build-dependencies = [
        { name = "build" },
        { name = "setuptools" },
    ]

    # Explicitly mark whether this package's sdist contains native
    # (C/C++/Cython/Rust/...) sources. Optional. Overrides the automatic
    # detection performed by the sdist configure tool (see
    # //uv/private/sdist_configure:defs.bzl):
    #   true  — force a platform-specific `pep517_native_whl` build with
    #           the CC toolchain plumbed into the build action.
    #   false — force a pure-Python `pep517_whl` build.
    # When omitted, the configure tool's detection decides.
    native = true

The `package.entry-points.console-scripts` table seen in some annotation
files is reserved for pre-declaring console-script targets; it is NOT
currently consumed (see the commented-out `declare_entrypoint` tag in
//uv/private/extension:defs.bzl).

## Relationship to standards

This format is bespoke because no uv or packaging standard covers it:

- `build-dependencies`: PEP 518's `[build-system] requires` [2] is the
  standard declaration, but it lives *inside* the sdist and is only
  knowable after download — the configure tool reads it when present.
  PEP 751 (pylock.toml) explicitly rejected locking build requirements
  for sdists [1], and `uv.lock` likewise doesn't record them, so the
  lock-level gap is intentionally unstandardized. uv's own
  `[tool.uv] extra-build-dependencies` [3] is a nonstandard analog of
  this annotation and a candidate for the extension to honor from
  `pyproject.toml` in the future.
- `native`: no standard exists. Wheel platform tags (PEP 425) describe
  the *built output*, not the sdist. PEP 725's `[external]
  build-requires` with virtual deps like `dep:virtual/compiler/c` [4]
  would be a standard in-sdist signal of nativeness, but it is still a
  Draft (as of 2026-06); if accepted, the configure tool could consume
  it as a detection input. uv itself has no native/pure distinction —
  it only matters here for choosing `pep517_whl` vs `pep517_native_whl`
  and the associated toolchain plumbing.

[1] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
[2] https://peps.python.org/pep-0518/
[3] https://docs.astral.sh/uv/reference/settings/#extra-build-dependencies
[4] https://peps.python.org/pep-0725/
"""

def parse_annotations(annotations, resolve, src = "<annotations>"):
    """Parse a decoded annotations file into per-package annotation tables.

    Args:
        annotations: The decoded TOML document (a dict).
        resolve: Callback taking a `{name, version?}` package dict and
            returning the `(project_id, name, version, extra)` lock key it
            resolves to, or None when the package isn't in the lockfile
            (the entry is then skipped, allowing shared annotation files).
        src: Label string of the annotations file, for error messages.

    Returns:
        A struct with fields:
            build_deps: dict of lock key -> list of resolved build dep keys.
                Entries with any unresolvable build dependency are omitted.
            native: dict of lock key -> bool, for packages carrying an
                explicit `native = true/false` annotation.
    """
    build_deps = {}
    native = {}

    for package in annotations.get("package", []):
        k = resolve(package)
        if k == None:
            # Allow a shared annotation file to include entries for other locks.
            continue

        if "native" in package:
            if type(package["native"]) != "bool":
                fail("Annotation `native` for package {} in {} must be a boolean, got {}".format(package["name"], src, repr(package["native"])))
            native[k] = package["native"]

        deps = []
        skip = False
        for dep in package.get("build-dependencies", []):
            resolved = resolve(dep)
            if resolved == None:
                skip = True
                break
            deps.append(resolved)
        if not skip:
            build_deps[k] = deps

    return struct(
        build_deps = build_deps,
        native = native,
    )
