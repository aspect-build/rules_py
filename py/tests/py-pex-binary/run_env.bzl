"""Writes a target's RunEnvironmentInfo as JSON."""

def _run_env_json_impl(ctx):
    run_env = ctx.attr.target[RunEnvironmentInfo]
    out = ctx.actions.declare_file(ctx.attr.name + ".json")
    ctx.actions.write(out, json.encode_indent({
        "environment": run_env.environment,
        "inherited_environment": run_env.inherited_environment,
    }) + "\n")
    return [DefaultInfo(files = depset([out]))]

run_env_json = rule(
    implementation = _run_env_json_impl,
    attrs = {"target": attr.label(mandatory = True, providers = [RunEnvironmentInfo])},
)
