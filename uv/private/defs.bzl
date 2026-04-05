"Internal helpers."

load("//py/private:providers.bzl", "PyWheelInfo")

def _whl_requirements_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        s[PyWheelInfo].files
        for s in ctx.attr.srcs
        if PyWheelInfo in s
    ]))]

whl_requirements = rule(
    implementation = _whl_requirements_impl,
    attrs = {
        "srcs": attr.label_list(),
    },
)
