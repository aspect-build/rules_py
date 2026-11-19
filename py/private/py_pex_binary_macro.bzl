"""The public py_pex_binary, which picks the rule by whether it builds a scie."""

load(":py_pex_binary.bzl", "SCIE_DOC", _py_pex_rule = "py_pex_binary", _py_pex_scie_rule = "py_pex_scie_binary")

def _py_pex_binary_impl(name, visibility, scie, target_compatible_with, **kwargs):
    if scie:
        # Incompatible, rather than failing analysis, on a target platform
        # science cannot build a scie for.
        supported = select({
            Label("@rules_py_scie_tools//:supported"): [],
            "//conditions:default": [Label("@platforms//:incompatible")],
        })
        _py_pex_scie_rule(
            name = name,
            visibility = visibility,
            scie = scie,
            target_compatible_with = supported + (target_compatible_with or []),
            **kwargs
        )
    else:
        _py_pex_rule(name = name, visibility = visibility, target_compatible_with = target_compatible_with, **kwargs)

py_pex_binary = macro(
    doc = """\
Build a pex executable from a py_binary.

`bazel run` on the pex gets the `binary`'s `env` and `env_inherit`, with
`BAZEL_TARGET`, `BAZEL_TARGET_NAME` and `BAZEL_WORKSPACE` naming the pex.
`env` paths must use `$(rlocationpath)`: the pex resolves runfiles from its own
archive, so `$(rootpath)`, `$(location)` and `$(execpath)` values do not exist.
Outside of Bazel only `inject_env` applies.

A plain pex's target is of kind `py_pex_binary`, a scie's of kind `py_pex_scie_binary`.
""",
    implementation = _py_pex_binary_impl,
    inherit_attrs = _py_pex_rule,
    attrs = {
        "scie": attr.string(
            doc = SCIE_DOC,
            values = ["", "eager"],
            default = "",
            # Picks the rule, so it cannot be a select().
            configurable = False,
        ),
    },
)
