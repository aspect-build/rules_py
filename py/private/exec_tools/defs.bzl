# Copyright 2024 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Exec-configured Python interpreter toolchain.

Hoisted from rules_python to avoid depending on its private API and to
support rules_python >= 1.0.0 (exec_runtime was added in 1.9.0).
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

PyExecToolsInfo = provider(
    doc = "Build tools used as part of building Python programs.",
    fields = {
        "exec_runtime": "PyRuntimeInfo | None: the py3_runtime from the exec interpreter.",
    },
)

def _py_exec_tools_toolchain_impl(ctx):
    exec_interpreter = ctx.attr.exec_interpreter

    exec_runtime = None
    if exec_interpreter != None and platform_common.ToolchainInfo in exec_interpreter:
        tc = exec_interpreter[platform_common.ToolchainInfo]
        exec_runtime = getattr(tc, "py3_runtime", None)

    return [platform_common.ToolchainInfo(
        exec_tools = PyExecToolsInfo(
            exec_runtime = exec_runtime,
        ),
    )]

py_exec_tools_toolchain = rule(
    implementation = _py_exec_tools_toolchain_impl,
    attrs = {
        "exec_interpreter": attr.label(
            default = "//py/private/exec_tools:current_interpreter_executable",
            providers = [DefaultInfo, platform_common.ToolchainInfo],
            cfg = "exec",
        ),
    },
)

def _current_interpreter_executable_impl(ctx):
    toolchain = ctx.toolchains[PY_TOOLCHAIN]
    runtime = toolchain.py3_runtime

    # Name the output after the interpreter binary so tools like pyenv that
    # use $0 to re-exec work correctly.
    if runtime.interpreter:
        executable = ctx.actions.declare_file(runtime.interpreter.basename)
        ctx.actions.symlink(output = executable, target_file = runtime.interpreter, is_executable = True)
    else:
        executable = ctx.actions.declare_symlink(paths.basename(runtime.interpreter_path))
        ctx.actions.symlink(output = executable, target_path = runtime.interpreter_path)

    return [
        toolchain,
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles([executable], transitive_files = runtime.files),
        ),
    ]

current_interpreter_executable = rule(
    implementation = _current_interpreter_executable_impl,
    toolchains = [PY_TOOLCHAIN],
    executable = True,
)
