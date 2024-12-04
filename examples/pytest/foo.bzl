def _impl(ctx):
    e = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(e, content = "exit 0")
    return DefaultInfo(
        executable = e,
    )

lol_test = rule(
    implementation = _impl,
    test = True,
)
