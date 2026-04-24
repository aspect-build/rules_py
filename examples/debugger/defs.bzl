"""Wrapper macro that injects debugpy as a wrapper entrypoint."""

load("@aspect_rules_py//py:defs.bzl", _py_binary = "py_binary")

def _debug_main_impl(ctx):
    """Generate a debugpy wrapper that runs the real entrypoint."""
    main_file = ctx.file.main.short_path
    if main_file.endswith(".py"):
        main_file = main_file[:-3]
    module = main_file.replace("/", ".")

    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.out,
        substitutions = {
            "%%MAIN_MODULE%%": module,
        },
    )
    return [DefaultInfo(files = depset([ctx.outputs.out]))]

_debug_main = rule(
    implementation = _debug_main_impl,
    attrs = {
        "main": attr.label(
            allow_single_file = [".py"],
            mandatory = True,
            doc = "The real application entrypoint to wrap.",
        ),
        "_template": attr.label(
            default = ":_debug_main.py.tpl",
            allow_single_file = True,
        ),
        "out": attr.output(mandatory = True),
    },
)

def py_debuggable_binary(name, srcs = [], deps = [], debug_deps = [], **kwargs):
    """A py_binary that wraps the entrypoint with debugpy in debug mode.

    In debug mode (the default), the binary's main is replaced with a
    debugpy wrapper that starts a DAP listener before importing the real
    application. The IDE can attach to the listener before any app code
    runs.

    In prod mode, debug_deps and the debug wrapper are stripped.

    Args:
        name: Target name.
        srcs: Source files.
        deps: Production dependencies — always included.
        debug_deps: Debug-only dependencies (e.g. debugpy) — included unless mode=prod.
        **kwargs: Forwarded to py_binary.
    """
    main = kwargs.pop("main", None)

    debug_main_name = "_{}_debug_main".format(name)
    _debug_main(
        name = debug_main_name,
        main = main,
        out = debug_main_name + ".py",
    )

    _py_binary(
        name = name,
        srcs = srcs + select({
            "//:is_prod": [],
            "//conditions:default": [debug_main_name],
        }),
        main = select({
            "//:is_prod": main,
            "//conditions:default": debug_main_name + ".py",
        }),
        deps = deps + select({
            "//:is_prod": [],
            "//conditions:default": debug_deps,
        }),
        **kwargs
    )
