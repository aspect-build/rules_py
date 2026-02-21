load("@bazel_lib//lib:expand_template.bzl", "expand_template")
load("//py/unstable:defs.bzl", "py_venv_binary")

def py_entrypoint_binary(
        name,
        entrypoint,
        pkg,
        visibility = ["//visibility:public"]):
    main = "_{}_entrypoint".format(name)
    tmpl = Label("@aspect_rules_py//uv/private/py_entrypoint_binary:entrypoint.tmpl")

    if ":" not in entrypoint:
        fail("Invalid entrypoint coordinate")

    # <name> = <package_or_module>[:<object>[.<attr>[.<nested-attr>]*]]
    package, symbol = entrypoint.split(":")

    if "." in symbol:
        fn, tail = symbol.split(".", 1)
        alias = "{fn} = {fn}.{tail}\n".format(fn = fn, tail = tail)
    else:
        fn = symbol
        tail = ""
        alias = ""

    expand_template(
        name = main,
        template = tmpl,
        out = main + ".py",
        substitutions = {
            "{package}": package,
            "{fn}": fn,
            "{alias}": alias,
        },
    )

    py_venv_binary(
        name = name,
        main = main + ".py",
        srcs = [main],
        deps = [pkg],
        visibility = visibility,
    )

def py_console_script_binary(
        name,
        script,
        pkg,
        visibility = ["//visibility:public"]):
    main = "_{}_entrypoint".format(name)
    tmpl = Label("@aspect_rules_py//uv/private/py_entrypoint_binary:entrypoint.tmpl")

    search_tool = "_{}_search_binary".format(name)
    search_py = Label("@aspect_rules_py//uv/private/py_entrypoint_binary:search.py")
    search = "_{}_search".format(name)

    py_venv_binary(
        name = search_tool,
        deps = [pkg],
        main = search_py,
        srcs = [search_py],
    )

    native.genrule(
        name = search,
        tools = [
            search_tool,
        ],
        outs = [
            main + ".py",
        ],
        srcs = [
            tmpl,
        ],
        cmd = "$(location {}) --template=\"$(location {})\" --script=\"{}\" >\"$@\"".format(search_tool, tmpl, script),
    )

    py_venv_binary(
        name = name,
        main = search,
        srcs = [search],
        deps = [pkg],
        visibility = visibility,
    )
