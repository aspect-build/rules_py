# Migrating rules from rules_python to rules_py

rules_py tries to closely mirror the API of rules_python, so a migration is a "drop-in replacement" for the majority of use cases.

## Replace load statements

Instead of loading from `@rules_python//python:defs.bzl`, you load from `@aspect_rules_py//py:defs.bzl`.
The rest of the BUILD file can remain the same.

If you use Gazelle, see the note on [using with Gazelle](/README.md#using-with-gazelle)