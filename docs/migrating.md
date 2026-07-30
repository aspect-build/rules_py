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

## rules_python provider compatibility layer

Mid-migration, a `@rules_python` target depending on an already-converted
rules_py library fails analysis with `does not have mandatory providers:
'PyInfo'`. To keep it building:

```
# .bazelrc
common --@aspect_rules_py//py:emit_rules_python_providers
```

`py_library` then also emits the rules_python providers. Temporary scaffolding:
only `py_library` participates, [virtual deps](/docs/virtual_deps.md) are not
expressible in those providers (resolve them concretely in `deps`), and the
flag belongs in `.bazelrc` only until the last rules_python target is gone.

## Remaining notes

Users are encouraged to send a Pull Request to add more documentation as they uncover issues during migrations.
