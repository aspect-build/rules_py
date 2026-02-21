"""**EXPERIMENTAL**: Protobuf and gRPC support for Python.

This API is subject to breaking changes outside our usual semver policy.
In a future release of rules_py this should become stable.

### Typical setup

1. Choose any code generator plugin for protoc.
   For example, https://pypi.org/project/grpcio-tools/ which provides `protoc` and
   Python gRPC code generation.
2. Declare a binary target that runs the generator, for example:

```starlark
load("@rules_python//python/entry_points:py_console_script_binary.bzl", "py_console_script_binary")

py_console_script_binary(
    name = "protoc-gen-grpc",
    pkg = "@pypi//grpcio_tools",
    script = "protoc",
)
```
3. Instead, it's also possible to use the Python plugin which is built-in to protoc.
3. Define a `py_proto_toolchain` that specifies the plugin. See the rule documentation below.
4. Update `MODULE.bazel` to register it, typically with
   `register_toolchains("//tools/toolchains:all")`.

### Usage

Write `proto_library` targets as usual, or have Gazelle generate them.
Then reference them anywhere a `py_library` could appear.
Note this attribute is not supported by rules_python, meaning your BUILD files will be specific to rules_py.

For example:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_library")
load("@protobuf//bazel:proto_library.bzl", "proto_library")

proto_library(
    name = "eliza_proto",
    srcs = ["eliza.proto"],
)

py_library(
    name = "proto",
    deps = [":eliza_proto"],
)
```
"""

load("@protobuf//bazel/toolchains:proto_lang_toolchain.bzl", "proto_lang_toolchain")
load("//py/private:proto.bzl", "LANG_PROTO_TOOLCHAIN")

def py_proto_toolchain(name, plugin_name, plugin_options, plugin_bin, runtime = None, **kwargs):
    """Define a proto_lang_toolchain that uses the plugin.

    Example:

    ```starlark
    py_proto_toolchain(
        name = "gen_es_protoc_plugin",
        plugin_bin = ":protoc-gen-grpc",
        plugin_name = "python",
        plugin_options = [
        ],
        runtime = "@pypi//:protobuf",
    )
    ```

    Args:
        name: The name of the toolchain. A target named [name]_toolchain is also created, which is the one to be used in register_toolchains.
        plugin_name: The `NAME` of the plugin program, used in command-line flags to protoc, as follows:

            > `protoc --plugin=protoc-gen-NAME=path/to/mybinary --NAME_out=OUT_DIR`

            See https://protobuf.dev/reference/cpp/api-docs/google.protobuf.compiler.plugin

        plugin_options: (List of strings) Command line flags used to invoke the plugin,
            based on documentation for the generator.

        plugin_bin: The plugin to use. This should be the label of a binary target that you declared in step 2 above.
            If `None`, the Python plugin which is built-in to protoc will be used.

        runtime: Optional runtime dependency imported by generated code.

        **kwargs: Additional arguments to pass to the [proto_lang_toolchain](https://bazel.build/reference/be/protocol-buffer#proto_lang_toolchain) rule.
    """
    command_line_flags = ["--{}_opt=%s".format(plugin_name) % o for o in plugin_options]
    command_line_flags.append("--{}_out=$(OUT)".format(plugin_name))
    attrs = dict(kwargs)
    if runtime != None:
        attrs["runtime"] = runtime

    proto_lang_toolchain(
        name = name,
        command_line = " ".join(command_line_flags),
        plugin_format_flag = "--plugin=protoc-gen-{}=%s".format(plugin_name),
        toolchain_type = LANG_PROTO_TOOLCHAIN,
        plugin = plugin_bin,
        **attrs
    )
