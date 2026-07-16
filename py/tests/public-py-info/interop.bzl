"""Consumes either public Python provider and forwards it to rules_py."""

load("//py:defs.bzl", "PyInfo", "RulesPythonPyInfo", "get_py_info", "has_py_info")

def _dual_py_info_impl(ctx):
    native = ctx.attr.native
    rules = ctx.attr.rules
    return [
        DefaultInfo(
            files = depset(transitive = [native[DefaultInfo].files, rules[DefaultInfo].files]),
            runfiles = native[DefaultInfo].default_runfiles.merge(rules[DefaultInfo].default_runfiles),
        ),
        native[RulesPythonPyInfo],
        rules[PyInfo],
    ]

dual_py_info = rule(
    implementation = _dual_py_info_impl,
    attrs = {
        "native": attr.label(mandatory = True, providers = [[RulesPythonPyInfo]]),
        "rules": attr.label(mandatory = True, providers = [[PyInfo]]),
    },
)

def _public_py_info_consumer_impl(ctx):
    dep = ctx.attr.dep
    if not has_py_info(dep):
        fail("{} does not provide Python sources".format(dep.label))
    info = get_py_info(dep)
    if ctx.attr.expected_source not in [source.basename for source in info.transitive_sources.to_list()]:
        fail("{} dropped {} from the selected Python provider".format(dep.label, ctx.attr.expected_source))
    if not any([path.endswith("/" + ctx.attr.expected_import) for path in info.imports.to_list()]):
        fail("{} dropped the {} import root".format(dep.label, ctx.attr.expected_import))
    if RulesPythonPyInfo in dep:
        stubs = dep[RulesPythonPyInfo].transitive_pyi_files.to_list()
        if ctx.attr.expected_stub not in [stub.basename for stub in stubs]:
            fail("{} dropped native stub {}".format(dep.label, ctx.attr.expected_stub))
    return [
        DefaultInfo(
            files = dep[DefaultInfo].files,
            runfiles = dep[DefaultInfo].default_runfiles,
        ),
        PyInfo(
            imports = info.imports,
            transitive_sources = info.transitive_sources,
            virtual_dependencies = depset(),
            virtual_resolutions = depset(),
        ),
    ]

public_py_info_consumer = rule(
    implementation = _public_py_info_consumer_impl,
    attrs = {
        "dep": attr.label(mandatory = True, providers = [[PyInfo], [RulesPythonPyInfo]]),
        "expected_import": attr.string(mandatory = True),
        "expected_source": attr.string(mandatory = True),
        "expected_stub": attr.string(),
    },
)
