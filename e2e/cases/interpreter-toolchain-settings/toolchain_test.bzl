"""Analysis checks for target Python toolchains and executor Python tools."""

load("@aspect_rules_py//py/private:transitions.bzl", "python_transition")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

_CC_TOOLCHAIN = "@rules_python//python/cc:toolchain_type"
_EXEC_TOOLS_TOOLCHAIN = "@rules_python//python:exec_tools_toolchain_type"
_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

_VersionValuesInfo = provider(fields = ["aspect", "rules_python"])

def _assert_equal(description, expected, actual):
    if actual != expected:
        fail("{}: expected {}, got {}".format(description, expected, actual))

def _repository(file):
    owner = str(file.owner)
    separator = owner.find("//")
    if separator < 0:
        fail("Cannot identify the repository owning {}".format(file.path))
    return owner[:separator]

def _library_files(cc_info):
    files = []
    for linker_input in cc_info.linking_context.linker_inputs.to_list():
        for library in linker_input.libraries:
            for field in [
                "dynamic_library",
                "interface_library",
                "pic_static_library",
                "resolved_symlink_dynamic_library",
                "resolved_symlink_interface_library",
                "static_library",
            ]:
                file = getattr(library, field, None)
                if file != None:
                    files.append(file)
    return files

def _check_runtime_mode(name, runtime, python_version, abi_flags):
    if runtime == None:
        fail("{} did not resolve a Python runtime".format(name))
    if runtime.interpreter == None:
        fail("{} resolved a non-hermetic Python runtime".format(name))

    version_info = runtime.interpreter_version_info
    major, minor = python_version.split(".")
    _assert_equal("{} major".format(name), int(major), version_info.major)
    _assert_equal("{} minor".format(name), int(minor), version_info.minor)
    _assert_equal("{} ABI flags".format(name), abi_flags, runtime.abi_flags)
    _assert_equal(
        "{} pyc tag".format(name),
        "cpython-{}".format(python_version.replace(".", "")),
        runtime.pyc_tag,
    )
    return version_info

def _check_runtime(name, runtime, python_version, micro, releaselevel, serial, abi_flags):
    version_info = _check_runtime_mode(name, runtime, python_version, abi_flags)
    _assert_equal("{} micro".format(name), micro, version_info.micro)
    _assert_equal("{} release level".format(name), releaselevel, version_info.releaselevel)
    _assert_equal("{} release serial".format(name), serial, version_info.serial)
    return version_info

def _check_matching_versions(target_version, exec_version):
    for field in ["major", "minor", "micro", "releaselevel", "serial"]:
        _assert_equal(
            "target/exec {}".format(field),
            getattr(target_version, field),
            getattr(exec_version, field),
        )

def _check_cc_toolchain(name, cc, python_version, runtime_repo):
    _assert_equal("{} version".format(name), python_version, cc.python_version)

    header_repos = {
        _repository(header): None
        for header in cc.headers.providers_map["CcInfo"].compilation_context.headers.to_list()
        if header.owner != None
    }
    _assert_equal(
        "{} header repositories".format(name),
        [runtime_repo],
        sorted(header_repos.keys()),
    )

    if cc.libs == None:
        fail("{} did not provide Python libraries".format(name))
    library_repos = {
        _repository(library): None
        for library in _library_files(cc.libs.providers_map["CcInfo"])
        if library.owner != None
    }
    _assert_equal(
        "{} library repositories".format(name),
        [runtime_repo],
        sorted(library_repos.keys()),
    )

def _interpreter_toolchain_check_impl(ctx):
    runtime = ctx.toolchains[_RUNTIME_TOOLCHAIN].py3_runtime
    cc = ctx.toolchains[_CC_TOOLCHAIN].py_cc_toolchain
    exec_tools = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].exec_tools
    exec_runtime = exec_tools.exec_runtime

    target_version = _check_runtime(
        "runtime toolchain",
        runtime,
        ctx.attr.python_version,
        ctx.attr.micro,
        ctx.attr.releaselevel,
        ctx.attr.serial,
        ctx.attr.abi_flags,
    )
    exec_version = _check_runtime(
        "exec-tools runtime",
        exec_runtime,
        ctx.attr.python_version,
        ctx.attr.micro,
        ctx.attr.releaselevel,
        ctx.attr.serial,
        ctx.attr.abi_flags,
    )
    _check_matching_versions(target_version, exec_version)
    runtime_repo = _repository(runtime.interpreter)
    exec_runtime_repo = _repository(exec_runtime.interpreter)
    _check_cc_toolchain("C toolchain", cc, ctx.attr.python_version, runtime_repo)
    expected_repo_fragment = "+python_{}_".format(ctx.attr.python_version.replace(".", "_"))
    if expected_repo_fragment not in runtime_repo:
        fail(
            "runtime resolved from {}, expected a python_interpreters repository containing {}".format(
                runtime_repo,
                expected_repo_fragment,
            ),
        )
    if exec_tools.exec_interpreter == None:
        fail("exec-tools toolchain did not provide an exec interpreter")
    exec_interpreter = exec_tools.exec_interpreter[DefaultInfo].files_to_run.executable
    if exec_interpreter == None:
        fail("exec-tools toolchain did not provide an executable interpreter")
    _assert_equal(
        "exec-tools interpreter repository",
        exec_runtime_repo,
        _repository(exec_interpreter),
    )
    if exec_tools.precompiler == None:
        fail("exec-tools toolchain did not provide rules_python's precompiler")

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, runtime_repo + "\n" + exec_runtime_repo + "\n")
    return [DefaultInfo(files = depset([out]))]

interpreter_toolchain_check = rule(
    implementation = _interpreter_toolchain_check_impl,
    attrs = {
        "abi_flags": attr.string(mandatory = True),
        "micro": attr.int(mandatory = True),
        "python_version": attr.string(mandatory = True),
        "releaselevel": attr.string(mandatory = True),
        "serial": attr.int(mandatory = True),
    },
    toolchains = [
        _RUNTIME_TOOLCHAIN,
        _CC_TOOLCHAIN,
        _EXEC_TOOLS_TOOLCHAIN,
    ],
)

def _exec_tools_check_impl(ctx):
    runtime = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].exec_tools.exec_runtime
    if runtime == None or runtime.interpreter == None:
        fail("exec-tools check did not resolve a hermetic Python runtime")
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, str(runtime.interpreter_version_info))
    return [DefaultInfo(files = depset([out]))]

exec_tools_check = rule(
    implementation = _exec_tools_check_impl,
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
)

def _cross_platform_interpreter_check_impl(ctx):
    runtime = ctx.toolchains[_RUNTIME_TOOLCHAIN].py3_runtime
    cc = ctx.toolchains[_CC_TOOLCHAIN].py_cc_toolchain
    exec_tools = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].exec_tools
    exec_runtime = exec_tools.exec_runtime

    target_version = _check_runtime(
        "runtime toolchain",
        runtime,
        ctx.attr.python_version,
        ctx.attr.micro,
        ctx.attr.releaselevel,
        ctx.attr.serial,
        ctx.attr.abi_flags,
    )
    exec_version = _check_runtime(
        "exec-tools runtime",
        exec_runtime,
        ctx.attr.python_version,
        ctx.attr.micro,
        ctx.attr.releaselevel,
        ctx.attr.serial,
        ctx.attr.abi_flags,
    )
    _check_matching_versions(target_version, exec_version)

    runtime_repo = _repository(runtime.interpreter)
    exec_runtime_repo = _repository(exec_runtime.interpreter)
    _check_cc_toolchain("target C toolchain", cc, ctx.attr.python_version, runtime_repo)
    for description, fragment, repository in [
        ("runtime repository platform", ctx.attr.runtime_repository_platform, runtime_repo),
        ("exec-tools repository platform", ctx.attr.exec_repository_platform, exec_runtime_repo),
    ]:
        if fragment not in repository:
            fail("{}: expected {} in {}".format(description, fragment, repository))
    if exec_tools.exec_interpreter == None:
        fail("exec-tools toolchain did not provide an exec interpreter")
    exec_interpreter = exec_tools.exec_interpreter[DefaultInfo].files_to_run.executable
    if exec_interpreter == None:
        fail("exec-tools toolchain did not provide an executable interpreter")
    _assert_equal(
        "exec-tools interpreter repository",
        exec_runtime_repo,
        _repository(exec_interpreter),
    )
    if exec_tools.precompiler == None:
        fail("exec-tools toolchain did not provide rules_python's precompiler")

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, runtime_repo + "\n" + exec_runtime_repo + "\n")
    return [DefaultInfo(files = depset([out]))]

cross_platform_interpreter_check = rule(
    implementation = _cross_platform_interpreter_check_impl,
    attrs = {
        "abi_flags": attr.string(mandatory = True),
        "exec_repository_platform": attr.string(mandatory = True),
        "micro": attr.int(mandatory = True),
        "python_version": attr.string(mandatory = True),
        "releaselevel": attr.string(mandatory = True),
        "runtime_repository_platform": attr.string(mandatory = True),
        "serial": attr.int(mandatory = True),
    },
    toolchains = [
        _RUNTIME_TOOLCHAIN,
        _CC_TOOLCHAIN,
        _EXEC_TOOLS_TOOLCHAIN,
    ],
)

def _library_paths(target):
    return [file.short_path for file in _library_files(target[CcInfo])]

def _require_suffix(paths, suffix, description):
    matches = [path for path in paths if path.endswith("/" + suffix)]
    if len(matches) != 1:
        fail("{}: expected one {}, got {}".format(description, suffix, matches))

def _windows_repository_check_impl(ctx):
    runtime_paths = [file.short_path for file in ctx.attr.runtime_files[DefaultInfo].files.to_list()]
    for suffix in [
        "DLLs/tcl86t.dll",
        "include/Python.h",
        "python.exe",
        ctx.attr.abi3_dll,
        ctx.attr.full_dll,
    ]:
        _require_suffix(runtime_paths, suffix, "Windows runtime files")

    for target, description in [
        (ctx.attr.full_headers, "full Python headers"),
        (ctx.attr.abi3_headers, "ABI3 Python headers"),
    ]:
        header_paths = [
            file.short_path
            for file in target[CcInfo].compilation_context.headers.to_list()
        ]
        _require_suffix(header_paths, "include/Python.h", description)

    _require_suffix(
        _library_paths(ctx.attr.full_headers),
        "libs/" + ctx.attr.full_import_library,
        "full Python header interface",
    )
    _require_suffix(
        _library_paths(ctx.attr.abi3_headers),
        "libs/" + ctx.attr.abi3_import_library,
        "ABI3 Python header interface",
    )
    lib_paths = _library_paths(ctx.attr.libs)
    for suffix in [
        ctx.attr.abi3_dll,
        ctx.attr.full_dll,
        "libs/" + ctx.attr.abi3_import_library,
        "libs/" + ctx.attr.full_import_library,
    ]:
        matches = [path for path in lib_paths if path.endswith("/" + suffix)]
        if not matches:
            fail("Python libraries: expected {}, got {}".format(suffix, lib_paths))

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "Windows PBS runtime, headers, and import libraries are complete\n")
    return [DefaultInfo(files = depset([out]))]

windows_repository_check = rule(
    implementation = _windows_repository_check_impl,
    attrs = {
        "abi3_dll": attr.string(mandatory = True),
        "abi3_headers": attr.label(mandatory = True, providers = [CcInfo]),
        "abi3_import_library": attr.string(mandatory = True),
        "full_dll": attr.string(mandatory = True),
        "full_headers": attr.label(mandatory = True, providers = [CcInfo]),
        "full_import_library": attr.string(mandatory = True),
        "libs": attr.label(mandatory = True, providers = [CcInfo]),
        "runtime_files": attr.label(mandatory = True),
    },
)

def _version_probe_impl(ctx):
    return [_VersionValuesInfo(
        aspect = ctx.attr._aspect[BuildSettingInfo].value,
        rules_python = ctx.attr._rules_python[BuildSettingInfo].value,
    )]

_version_probe = rule(
    implementation = _version_probe_impl,
    attrs = {
        "_aspect": attr.label(default = "@python_interpreters//:python_version"),
        "_rules_python": attr.label(default = "@rules_python//python/config_settings:python_version"),
    },
)

def _version_transition_check_impl(ctx):
    if len(ctx.attr.probe) != 1:
        fail("expected one transitioned version probe, got {}".format(len(ctx.attr.probe)))
    values = ctx.attr.probe[0][_VersionValuesInfo]
    expected = ctx.attr.expected or ctx.attr._aspect[BuildSettingInfo].value
    _assert_equal("Aspect version after transition", expected, values.aspect)
    _assert_equal("rules_python version after transition", expected, values.rules_python)
    return []

_version_transition_check = rule(
    implementation = _version_transition_check_impl,
    attrs = {
        "expected": attr.string(),
        "probe": attr.label(cfg = python_transition, mandatory = True),
        "python_version": attr.string(),
        "_aspect": attr.label(default = "@python_interpreters//:python_version"),
    },
)

def version_transition_check(name, expected = "", python_version = ""):
    probe_name = name + "_probe"
    _version_probe(name = probe_name)
    _version_transition_check(
        name = name,
        expected = expected,
        probe = probe_name,
        python_version = python_version,
    )
