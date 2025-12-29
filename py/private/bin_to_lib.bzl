"""

Sometimes it is desirable for a python binary or venv to depend on another binary target or venv.
Here we reify bin-dep-bin semantics by transitioning a binary into a library if it is
 depended upon by another binary.

This functionality has the following benefits: 
1. py_venv_binary behaves more like the original py_binary rule.
2. Easier composition of venvs
3. Better merge semantics for existing binary rules.

"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyVirtualInfo")

def _bin_to_lib_transition_impl(settings, attr):
    return {
        "//py/private:bin_to_lib_flag": False,
    }

bin_to_lib_transition = transition(
    implementation = _bin_to_lib_transition_impl,
    inputs = [
        "//py/private:bin_to_lib_flag",
    ],
    outputs = [
        "//py/private:bin_to_lib_flag",
    ],
)

def _find_provider(providers, prov_type_name):
    for provider in providers:
        if type(provider) == prov_type_name:
            return provider
    return None

def _add_executable(ctx, lib_providers, bin_providers):
    new_providers = []
    bin_default_info = _find_provider(bin_providers, "DefaultInfo")
    for p in lib_providers:
        if type(p) == "DefaultInfo":
            new_providers.append(
                DefaultInfo(
                    files = p.files,
                    default_runfiles = p.default_runfiles,
                    # ugly hack: For some reason files_to_run is None so we must infer executable
                    #  from file list.
                    executable = bin_default_info.files.to_list()[0],
                ),
            )
            continue
        new_providers.append(p)
    return new_providers

def wrap_with_bin_to_lib(bin_rule, lib_rule):
    def helper(ctx):
        if not ctx.attr._binary_mode:
            fail("Wrapped rule missing required attributes.")

        bin_providers = bin_rule(ctx)
        if ctx.attr._binary_mode[BuildSettingInfo].value:
            return bin_providers

        lib_providers = lib_rule(ctx)

        # It appears that one cannot transition the executable status of a binary.
        #   This means we need to resolve an executable for binaries transitioned to libraries.
        return _add_executable(
            ctx,
            lib_providers,
            bin_providers,
        )

    return helper

bin_to_lib = struct(
    wrapper = wrap_with_bin_to_lib,
    attribs = dict({
        "_binary_mode": attr.label(
            default = "//py/private:bin_to_lib_flag",
        ),
        "deps": attr.label_list(
            doc = "Targets that produce Python code, commonly `py_library` rules.",
            providers = [[PyInfo], [PyVirtualInfo], [CcInfo]],
            cfg = bin_to_lib_transition,
        ),
    }),
)
