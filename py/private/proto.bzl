"""An aspect that generates Python code from .proto files.

The aspect converts a ProtoInfo provider into a PyInfo provider so that proto_library may be a dep to python rules.
"""

load("@protobuf//bazel/common:proto_common.bzl", "proto_common")
load("@protobuf//bazel/common:proto_info.bzl", "ProtoInfo")
load("@rules_python//python:defs.bzl", "PyInfo")

LANG_PROTO_TOOLCHAIN = Label("//py/private/toolchain:protoc_plugin_toolchain_type")

def _py_proto_aspect_impl(target, ctx):
    proto_info = target[ProtoInfo]
    proto_lang_toolchain_info = ctx.toolchains[LANG_PROTO_TOOLCHAIN].proto
    proto_deps = [d for d in ctx.rule.attr.deps if PyInfo in d]
    python_naming = lambda name: name.replace("-", "_").replace(".", "/")
    py_outputs = proto_common.declare_generated_files(
        actions = ctx.actions,
        proto_info = proto_info,
        extension = "_pb2.py",
        name_mapper = python_naming,
    )

    # FIXME: support generated stubs
    # generated_stubs = proto_common.declare_generated_files(
    #     actions = ctx.actions,
    #     proto_info = proto_info,
    #     extension = "_pb2.pyi",
    #     name_mapper = python_naming,
    # )

    # Determine root folder, mapping output paths to inputs, i.e. bazel-bin/arch/bin/foo to foo
    proto_root = proto_info.proto_source_root
    if proto_root.startswith(ctx.bin_dir.path):
        proto_root = proto_root[len(ctx.bin_dir.path) + 1:]

    # It's possible for proto_library to have only deps but no srcs
    if proto_info.direct_sources:
        additional_args = ctx.actions.args()
        # FIXME: this is plugin-specific and fishy
        # additional_args.add(py_outputs[0].root, format = "--pyi_out=%s")

        proto_common.compile(
            actions = ctx.actions,
            proto_info = proto_info,
            proto_lang_toolchain_info = proto_lang_toolchain_info,
            generated_files = py_outputs,
            plugin_output = py_outputs[0].root.path,
            additional_args = additional_args,
        )

    # Import path within the runfiles tree
    if proto_root.startswith("external/"):
        import_path = proto_root[len("external") + 1:]
    else:
        import_path = ctx.workspace_name + "/" + proto_root
    return [
        DefaultInfo(files = depset(py_outputs)),
        PyInfo(
            imports = depset(
                # Adding to PYTHONPATH so the generated modules can be
                # imported.  This is necessary when there is
                # strip_import_prefix, the Python modules are generated under
                # _virtual_imports. But it's undesirable otherwise, because it
                # will put the repo root at the top of the PYTHONPATH, ahead of
                # directories added through `imports` attributes.
                [import_path] if "_virtual_imports" in import_path else [],
                transitive = [dep.imports for dep in proto_deps],  # + [proto_lang_toolchain_info.runtime[PyInfo].imports]
            ),
            # direct_pyi_files = depset(direct = direct_pyi_files),
            # transitive_pyi_files = transitive_pyi_files,
            transitive_sources = depset(py_outputs, transitive = [dep.transitive_sources for dep in proto_deps]),
            # Proto always produces 2- and 3- compatible source files
            has_py2_only_sources = False,
            has_py3_only_sources = False,
            uses_shared_libraries = False,
        ),
    ]

py_proto_aspect = aspect(
    implementation = _py_proto_aspect_impl,
    # Traverse the "deps" graph edges starting from the target
    attr_aspects = ["deps"],
    # Only visit nodes that produce a ProtoInfo provider
    required_providers = [ProtoInfo],
    # Be a valid dependency of a py_library rule
    provides = [PyInfo],
    toolchains = [LANG_PROTO_TOOLCHAIN],
)
