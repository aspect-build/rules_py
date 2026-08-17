# Migrating rules from rules_python to rules_py

rules_py tries to closely mirror the API of rules_python.
Migration is a "drop-in replacement" for the majority of use cases.

## Replace load statements

Instead of loading from `@rules_python//python:defs.bzl`, load from `@aspect_rules_py//py:defs.bzl`.
The rest of the BUILD file can remain the same.

If using Gazelle, see the note on [using with Gazelle](/README.md#gazelle-integration)

## Update virtualenv paths

In rules_py v2.0, `py_venv_link` links the target's complete runfiles tree into
the workspace and prints the virtualenv's nested path below that link. Keeping
the runfiles layout intact preserves relative `.pth` entries and symlinks from
the virtualenv to its dependencies.

Paths that previously assumed the workspace link was the virtualenv root, such
as `.venv/bin`, must use the nested path instead. This includes IDE settings,
shell `PATH` entries, direnv configuration, and other automation. Run the link
target and use the path it prints rather than hard-coding a universal layout:

```sh
bazel run //path/to/package:target.venv_link
```

See [IDE Integration](/README.md#ide-integration) for target declarations and
editor configuration.

## `resolutions` is a plain dict

In rules_py v2.0, the `resolutions` attribute takes a plain dict mapping each
virtual dependency's package name to the label of an installed package that
provides it, on both the `py_binary`/`py_test` macros and the `py_venv` rule.
The `resolutions` helper struct is gone: delete the
`load("@aspect_rules_py//py:defs.bzl", "resolutions")` statement, replace
`resolutions.from_requirements(all_whl_requirements_by_package, requirement)`
with `{pkg: requirement(pkg) for pkg in all_whl_requirements_by_package.keys()}`,
and replace `.override({...})` with the dict union operator (`base | {...}`).
Resolution targets must now provide a `PyInfo` (rules_py's or rules_python's);
to remove a dependency entirely, resolve it to an empty `py_library` instead of
a `filegroup`. See [virtual deps](/docs/virtual_deps.md).

## rules_python provider compatibility layer

Mid-migration, a `@rules_python` target depending on an already-converted
rules_py library fails analysis with `does not have mandatory providers:
'PyInfo'`. To keep it building:

```
# .bazelrc
common --@aspect_rules_py//py:emit_rules_python_providers
```

`py_library`, `py_binary`, and `py_test` then also emit the rules_python
providers. Temporary scaffolding: [virtual deps](/docs/virtual_deps.md) are not
expressible in those providers (resolve them concretely in `deps`), and the
flag belongs in `.bazelrc` only until the last rules_python target is gone.

## Remaining notes

Users are encouraged to send a Pull Request to add more documentation as they uncover issues during migrations.
