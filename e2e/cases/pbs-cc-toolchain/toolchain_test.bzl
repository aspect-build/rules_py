"""Analysis checks for paired PBS runtime and C toolchains."""

_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
_PY_CC_TOOLCHAIN = "@rules_python//python/cc:toolchain_type"

def _link_library_files(provider_set):
    files = []
    cc_info = provider_set.providers_map["CcInfo"]
    for linker_input in cc_info.linking_context.linker_inputs.to_list():
        for library in linker_input.libraries:
            for artifact in [
                library.dynamic_library,
                library.interface_library,
                library.pic_static_library,
                library.static_library,
            ]:
                if artifact != None:
                    files.append(artifact)
    return files

def _check_same_pbs_repo(runtime, cc_toolchain):
    runtime_repo = runtime.interpreter.owner.repo_name
    payload = []
    header_sets = [cc_toolchain.headers]
    if cc_toolchain.headers_abi3 != None:
        header_sets.append(cc_toolchain.headers_abi3)
    for headers in header_sets:
        cc_info = headers.providers_map["CcInfo"]
        payload.extend(cc_info.compilation_context.headers.to_list())
        payload.extend(_link_library_files(headers))
    if cc_toolchain.libs != None:
        payload.extend(_link_library_files(cc_toolchain.libs))

    if not payload:
        fail("resolved Python C toolchain exposes no C payload files")
    for artifact in payload:
        if artifact.owner.repo_name != runtime_repo:
            fail("Python C toolchain file {} comes from repository {}, but runtime {} comes from repository {}".format(
                artifact,
                artifact.owner.repo_name,
                runtime.interpreter,
                runtime_repo,
            ))

def _check_windows_libraries(ctx, provider_set, description, stable_abi = False):
    suffix = "t" if ctx.attr.freethreaded else ""
    stem = "python3" if stable_abi else "python{}{}".format(
        ctx.attr.python_version.replace(".", ""),
        suffix,
    )
    libraries = sorted([artifact.basename for artifact in _link_library_files(provider_set)])
    expected = ["{}.lib".format(stem)]
    if libraries != expected:
        fail("{}: expected import library {}, got {}".format(
            description,
            expected,
            libraries,
        ))

def _check_cc_toolchain(ctx, cc_toolchain):
    if cc_toolchain.python_version != ctx.attr.python_version:
        fail("expected Python {} C toolchain, got {}".format(
            ctx.attr.python_version,
            cc_toolchain.python_version,
        ))
    if cc_toolchain.headers == None:
        fail("Python {} C toolchain has no headers".format(ctx.attr.python_version))
    if ctx.attr.expect_abi3 != (cc_toolchain.headers_abi3 != None):
        expected = "available" if ctx.attr.expect_abi3 else "unavailable"
        fail("expected Python {} ABI3 headers to be {}".format(ctx.attr.python_version, expected))
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    if is_windows:
        if cc_toolchain.libs == None:
            fail("Python {} Windows C toolchain has no import library".format(ctx.attr.python_version))
        _check_windows_libraries(ctx, cc_toolchain.headers, "full-ABI headers")
        _check_windows_libraries(ctx, cc_toolchain.libs, "full-ABI libraries")
        if cc_toolchain.headers_abi3 != None:
            _check_windows_libraries(ctx, cc_toolchain.headers_abi3, "stable-ABI headers", stable_abi = True)
    else:
        if cc_toolchain.libs == None:
            fail("Python {} POSIX C toolchain has no libpython".format(ctx.attr.python_version))
        suffix = "t" if ctx.attr.freethreaded else ""
        stem = "libpython{}{}".format(ctx.attr.python_version, suffix)
        is_macos = ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo])
        expected = [stem + ".dylib"] if is_macos else [
            stem + ".so",
            stem + ".so.1.0",
        ]
        libraries = sorted([artifact.basename for artifact in _link_library_files(cc_toolchain.libs)])
        if libraries != expected:
            fail("expected POSIX libpython files {}, got {}".format(expected, libraries))
        for description, headers in [
            ("full-ABI headers", cc_toolchain.headers),
            ("stable-ABI headers", cc_toolchain.headers_abi3),
        ]:
            if headers != None and _link_library_files(headers):
                fail("Python {} POSIX {} unexpectedly expose link libraries".format(
                    ctx.attr.python_version,
                    description,
                ))

def _pbs_toolchain_check_impl(ctx):
    runtime = ctx.toolchains[_RUNTIME_TOOLCHAIN].py3_runtime
    cc_toolchain = ctx.toolchains[_PY_CC_TOOLCHAIN].py_cc_toolchain

    if runtime.interpreter == None:
        fail("expected an in-build PBS runtime")
    if runtime.interpreter != ctx.file.expected_interpreter:
        fail("expected PBS runtime from {}, got {}".format(
            ctx.file.expected_interpreter.owner,
            runtime.interpreter.owner,
        ))

    version_info = runtime.interpreter_version_info
    runtime_version = "{}.{}".format(version_info.major, version_info.minor)
    if runtime_version != ctx.attr.python_version:
        fail("expected Python {} runtime, got {}".format(
            ctx.attr.python_version,
            runtime_version,
        ))
    expected_abi_flags = "t" if ctx.attr.freethreaded else ""
    if runtime.abi_flags != expected_abi_flags:
        fail("expected Python {} runtime ABI flags {}, got {}".format(
            ctx.attr.python_version,
            repr(expected_abi_flags),
            repr(runtime.abi_flags),
        ))
    _check_cc_toolchain(ctx, cc_toolchain)
    _check_same_pbs_repo(runtime, cc_toolchain)
    return []

_CC_ATTRS = {
    "expect_abi3": attr.bool(mandatory = True),
    "expected_interpreter": attr.label(allow_single_file = True, mandatory = True),
    "freethreaded": attr.bool(mandatory = True),
    "python_version": attr.string(mandatory = True),
    "_macos_constraint": attr.label(default = "@platforms//os:macos"),
    "_windows_constraint": attr.label(default = "@platforms//os:windows"),
}

pbs_toolchain_check = rule(
    implementation = _pbs_toolchain_check_impl,
    attrs = _CC_ATTRS,
    toolchains = [
        _RUNTIME_TOOLCHAIN,
        _PY_CC_TOOLCHAIN,
    ],
)
