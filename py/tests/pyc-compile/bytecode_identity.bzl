"""Bytecode of one single-source library under a chosen Python configuration."""

load("//py/private:pyc.bzl", "PycInfo")
load("//py/private:transitions.bzl", "python_transition")

def _configured_bytecode_impl(ctx):
    pycs = ctx.attr.lib[PycInfo].sourceless_pyc_files.to_list()
    if len(pycs) != 1:
        fail("{}: expected one bytecode file, got {}".format(ctx.label, pycs))

    # Configurations share the natural runfiles path; give each a distinct name
    # so a diff_test compares two files rather than one.
    out = ctx.actions.declare_file(ctx.label.name + ".pyc")
    ctx.actions.symlink(output = out, target_file = pycs[0])
    return [DefaultInfo(files = depset([out]))]

configured_bytecode = rule(
    implementation = _configured_bytecode_impl,
    attrs = {
        "lib": attr.label(providers = [PycInfo]),
        "python_version": attr.string(),
        "freethreaded": attr.string(values = ["", "true", "false"]),
    },
    cfg = python_transition,
)
