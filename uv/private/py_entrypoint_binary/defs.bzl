load("@bazel_lib//lib:expand_template.bzl", "expand_template")
load("//py/unstable:defs.bzl", "py_venv_binary")

def py_entrypoint_binary(
        name,
        coordinate,
        deps,
        visibility = ["//visibility:public"]):
    main = "_{}_entrypoint".format(name)

    # <name> = <package_or_module>[:<object>[.<attr>[.<nested-attr>]*]]
    package, symbol = coordinate.split(":")

    if "." in symbol:
        fn, tail = symbol.split(".", 1)
        alias = "{fn} = {fn}.{tail}\n".format(fn = fn, tail = tail)
    else:
        fn = symbol
        tail = ""
        alias = ""

    expand_template(
        name = main,
        template = Label("@aspect_rules_py//uv/private/py_entrypoint_binary:entrypoint.tmpl"),
        out = main + ".py",
        substitutions = {
            "{{package}}": package,
            "{{fn}}": fn,
            "{{alias}}": alias,
        },
    )

    py_venv_binary(
        name = name,
        main = main + ".py",
        srcs = [main],
        deps = deps,
        visibility = visibility,
    )
