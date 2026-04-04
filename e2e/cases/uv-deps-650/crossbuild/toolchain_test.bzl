"""Analysis-time toolchain resolution test utilities.

Provides a rule that materialises the resolved unpack toolchain binary path
into a file, so sh_test scripts can inspect which binary was selected.
"""

UNPACK_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:unpack_toolchain_type"

def _unpack_toolchain_path_impl(ctx):
    unpack_bin = ctx.toolchains[UNPACK_TOOLCHAIN].bin.bin
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, unpack_bin.path)
    return [DefaultInfo(files = depset([out]))]

unpack_toolchain_path = rule(
    doc = """Writes the resolved unpack toolchain binary path to a text file.

Used to verify that toolchain resolution picks the exec-platform binary even
when the target platform differs (cross-compilation scenario).
""",
    implementation = _unpack_toolchain_path_impl,
    toolchains = [UNPACK_TOOLCHAIN],
)
