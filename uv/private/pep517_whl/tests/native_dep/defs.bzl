"""Test shim: emulate `uv.override_package(toolchains=, env=)` by surfacing a
cc_library's include dir + static archive as make-vars."""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _dep_makevars_impl(ctx):
    cc_info = ctx.attr.lib[CcInfo]
    archives = []
    for linker_input in cc_info.linking_context.linker_inputs.to_list():
        for lib in linker_input.libraries:
            archive = lib.static_library or lib.pic_static_library
            if archive:
                archives.append(archive)
    if not archives:
        fail("cc_library {} produced no static archive".format(ctx.attr.lib.label))
    archive = archives[0]
    header = ctx.file.hdr

    return [
        # header + archive must be staged as build-action inputs;
        # pep517_native_whl stages each toolchain dep's DefaultInfo.files.
        DefaultInfo(files = depset([header, archive])),
        platform_common.TemplateVariableInfo({
            # Deliberately workspace-relative (execroot-valid, worktree-invalid):
            # the input under test.
            "DEP_INC": header.dirname,
            "DEP_LIB_A": archive.path,
        }),
    ]

dep_makevars = rule(
    implementation = _dep_makevars_impl,
    attrs = {
        "lib": attr.label(providers = [CcInfo], mandatory = True),
        "hdr": attr.label(allow_single_file = True, mandatory = True),
    },
)
