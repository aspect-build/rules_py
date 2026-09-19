"""Asserts which bytecode layout rules_py reuses from a rules_python library."""

load("@aspect_rules_py//py/private:pyc.bzl", "PycInfo", "pyc_aspect")
load("@rules_python//python:py_info.bzl", "PyInfo")

def _bytecode_reuse_check_impl(ctx):
    info = ctx.attr.library[PyInfo]
    advertised = {
        f: True
        for f in depset(transitive = [info.direct_pyc_files, info.transitive_implicit_pyc_files]).to_list()
    }
    entries = ctx.attr.library[PycInfo].direct_entries
    if len(entries) != 1:
        fail("{}: expected one bytecode entry, got {}".format(ctx.label, entries))
    entry = entries[0]
    reused = {
        "pycache": entry.pycache in advertised,
        "pyc": entry.pyc in advertised,
    }
    expected = {
        "pycache": ctx.attr.reused == "pycache",
        "pyc": ctx.attr.reused == "pyc",
    }
    if reused != expected:
        fail("{}: reused rules_python bytecode {}, expected {}".format(ctx.label, reused, expected))
    return [DefaultInfo()]

bytecode_reuse_check = rule(
    implementation = _bytecode_reuse_check_impl,
    attrs = {
        "library": attr.label(aspects = [pyc_aspect], providers = [PyInfo]),
        "reused": attr.string(values = ["none", "pyc", "pycache"]),
    },
)
