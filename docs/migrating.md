# Migrating rules from rules_python to rules_py

rules_py tries to closely mirror the API of rules_python.
Migration is a "drop-in replacement" for the majority of use cases.

## Replace load statements

Instead of loading from `@rules_python//python:defs.bzl`, load from `@aspect_rules_py//py:defs.bzl`.
The rest of the BUILD file can remain the same, except for bytecode attributes:
see [Converting precompile attributes](#converting-precompile-attributes).

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

## `py_binary` is not a dependency

In rules_py v2.0, listing a `py_binary` or `py_test` in `deps` fails analysis:
a launcher packages its own runfiles, which consumers cannot repackage as
library code. Depend on the `py_library` holding its sources instead, and put a
launcher another program runs in `data`, or in `py_image_layer`'s `binaries`.

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

## Converting precompile attributes

Both rulesets have a `precompile` attribute, but with different values and a
different owner. rules_python sets it per target to `enabled`, `disabled` or
`inherit`; rules_py sets it only on the launcher (`py_binary`, `py_test`) to
`off`, `pycache` or `sourceless`, and every first-party library the launcher
reaches is compiled for that mode. A converted `py_library` therefore drops all
of its `precompile*` attributes; rules_py's `py_library` has none and rejects
them.

| rules_python | rules_py |
| --- | --- |
| `py_library` `precompile`, `precompile_source_retention`, `precompile_invalidation_mode`, `precompile_optimize_level` | Remove; the consuming launcher selects the bytecode. |
| `py_binary`/`py_test` `precompile = "enabled"` or `pyc_collection = "include_pyc"`, sources kept | `precompile = "pycache"` |
| The same with `precompile_source_retention = "omit_source"` | `precompile = "sourceless"` |
| `precompile = "disabled"` or `pyc_collection = "disabled"` | `precompile = "off"`, the default |
| `precompile = "inherit"` or `pyc_collection = "inherit"` | Leave `precompile` unset to follow the flag. |
| `--@rules_python//python/config_settings:precompile=enabled` | `--@aspect_rules_py//py:precompile=pycache` |
| `--@rules_python//python/config_settings:precompile_source_retention=omit_source` | `--@aspect_rules_py//py:precompile=sourceless` |
| `precompile_invalidation_mode = "checked_hash"` | `--@aspect_rules_py//py:pyc_invalidation_mode=checked-hash`, for the whole build |
| `precompile_invalidation_mode = "unchecked_hash"` or `"auto"` | Nothing: `unchecked-hash` is the default, under every `-c` mode. |
| `precompile_optimize_level` | No equivalent. |

Source retention is part of the mode: `pycache` keeps sources beside
`__pycache__`, and `sourceless` replaces them with colocated `.pyc` files.
Invalidation is a build-wide flag rather than a per-target attribute, and
rules_py has no `timestamp` mode. Bytecode is always compiled at optimization
level 0; for optimized runs, use `pycache`, whose level-0 caches CPython ignores
under `-O`, running the sources instead. `pyc_collection` has no counterpart,
because a rules_py launcher always collects its dependencies' bytecode in its
mode.

## Bytecode for unconverted targets

rules_py's bytecode modes compile dependencies still built by rules_python rules
(`py_proto_library`, unconverted `py_library` targets) itself, and reuse any
bytecode rules_python already precompiled for them. Packages from a
rules_python pip hub are never compiled and run from source in every mode;
a rules_py uv hub installs wheels with bytecode.

rules_python precompiles only targets that set `precompile = "enabled"` or build
under `--@rules_python//python/config_settings:precompile=enabled`. Such a
dependency blocks a gradual migration in three cases, until it sets the
attribute shown, disables its precompilation, or is converted to rules_py:

- A nonzero `precompile_optimize_level` fails both bytecode modes at analysis,
  whichever source retention it uses: set `precompile_optimize_level = 0`. A
  srcs-less wrapper forwarding its `PyInfo` hides that attribute, so wrap only
  level-0 libraries.
- Under `--@aspect_rules_py//py:pyc_invalidation_mode=checked-hash`, reused
  `__pycache__` bytecode that is not checked-hash fails the build: set
  `precompile_invalidation_mode = "checked_hash"` (its default `auto` already is,
  outside `-c opt`).
- A source listed by both a rules_py target and a precompiling rules_python
  target fails analysis with conflicting actions on the natural bytecode paths
  (`off` declares no bytecode): list the source once.

Under `sourceless` a rules_python `py_library` still ships its sources from its
own runfiles, so rules_py also ships their `__pycache__` bytecode, which CPython
reads beside a present source; converting the library to rules_py's
`py_library` makes it sourceless.

## Remaining notes

Users are encouraged to send a Pull Request to add more documentation as they uncover issues during migrations.
