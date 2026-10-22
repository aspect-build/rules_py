"""Bytecode of one single-source library under a chosen Python configuration."""

load("//py/private:providers.bzl", "PycInfo")
load("//py/private:transitions.bzl", "python_transition")
load("//py/tests:pyc_testing.bzl", "precompile_transition")

def _configured_bytecode_impl(ctx):
    pycs = [entry.pyc for entry in ctx.attr.lib[0][PycInfo].direct_entries]
    if len(pycs) != 1:
        fail("{}: expected one bytecode file, got {}".format(ctx.label, pycs))

    # Configurations share the runfiles path; distinct names keep diff_test's inputs apart.
    out = ctx.actions.declare_file(ctx.label.name + ".pyc")
    ctx.actions.symlink(output = out, target_file = pycs[0])
    return [DefaultInfo(files = depset([out]))]

configured_bytecode = rule(
    implementation = _configured_bytecode_impl,
    attrs = {
        "lib": attr.label(providers = [PycInfo], cfg = precompile_transition),
        "python_version": attr.string(),
        "freethreaded": attr.string(values = ["", "true", "false"]),
    },
    cfg = python_transition,
)
