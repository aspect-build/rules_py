# Migrating rules from rules_python to rules_py

rules_py tries to closely mirror the API of rules_python.
Migration is a "drop-in replacement" for the majority of use cases.

## Replace load statements

Instead of loading from `@rules_python//python:defs.bzl`, load from `@aspect_rules_py//py:defs.bzl`.
The rest of the BUILD file can remain the same.

If using Gazelle, see the note on [using with Gazelle](/README.md#using-with-gazelle)

## Remaining notes

Users are encouraged to send a Pull Request to add more documentation as they uncover issues during migrations.
