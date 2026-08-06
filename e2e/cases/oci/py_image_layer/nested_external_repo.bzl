"""Fixture repo whose payload lives under a nested `external/` directory.

The canonical path becomes `<output_base>/external/<repo>/external/payload.txt`,
so it carries two `/external/` segments — the shape a wheel like sympy produces,
and what regressed in https://github.com/aspect-build/rules_py/issues/1398.
"""

def _nested_external_repo_impl(rctx):
    rctx.file("external/payload.txt", "nested-external-ok", executable = False)
    rctx.file("BUILD.bazel", 'exports_files(["external/payload.txt"])\n')

_nested_external_repo = repository_rule(implementation = _nested_external_repo_impl)

def _nested_external_impl(_):
    _nested_external_repo(name = "oci_nested_external")

nested_external = module_extension(implementation = _nested_external_impl)
