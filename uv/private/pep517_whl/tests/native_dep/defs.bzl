"""Expose an in-repo cc_library's header and archive as native-build make vars."""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _dep_makevars_impl(ctx):
    archives = [
        archive
        for linker_input in ctx.attr.lib[CcInfo].linking_context.linker_inputs.to_list()
        for lib in linker_input.libraries
        for archive in [lib.static_library or lib.pic_static_library]
        if archive
    ]
    if not archives:
        fail("cc_library {} produced no static archive".format(ctx.attr.lib.label))

    header = ctx.file.hdr
    archive = archives[0]
    ar = ctx.file.ar
    cc = ctx.file.cc
    return [
        DefaultInfo(files = depset([header, archive, ar, cc])),
        platform_common.TemplateVariableInfo({
            "DEP_INC": header.dirname,
            "DEP_LIB_A": archive.path,
            "DEP_AR": ar.path,
            "DEP_CC": cc.path,
        }),
    ]

dep_makevars = rule(
    implementation = _dep_makevars_impl,
    attrs = {
        "ar": attr.label(allow_single_file = True, mandatory = True),
        "cc": attr.label(allow_single_file = True, mandatory = True),
        "hdr": attr.label(allow_single_file = True, mandatory = True),
        "lib": attr.label(providers = [CcInfo], mandatory = True),
    },
)
