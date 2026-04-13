load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _config_probe_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(
        output = out,
        content = "\n".join([
            "python_version={}".format(ctx.attr._python_version[BuildSettingInfo].value),
            "rules_python_version={}".format(ctx.attr._rules_python_version[BuildSettingInfo].value),
            "dep_group={}".format(ctx.attr._dep_group[BuildSettingInfo].value),
            "freethreaded={}".format(ctx.attr._freethreaded[BuildSettingInfo].value),
            "",
        ]),
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

config_probe = rule(
    implementation = _config_probe_impl,
    attrs = {
        "_python_version": attr.label(
            default = "@aspect_rules_py//py/private/interpreter:python_version",
        ),
        "_rules_python_version": attr.label(
            default = "@rules_python//python/config_settings:python_version",
        ),
        "_dep_group": attr.label(
            default = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group",
        ),
        "_freethreaded": attr.label(
            default = "@aspect_rules_py//py/private/interpreter:freethreaded",
        ),
    },
)
