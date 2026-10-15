"""Import directories for targets carrying only `@rules_python`'s `PyInfo`.

Type checks need the execroot directories behind each import root (see
`ImportDirsInfo`). rules_py targets return their own; this aspect computes it
for `@rules_python` targets, such as rules_python's `py_library` and its
pip wheels, or protobuf's `py_proto_library`, from their import roots and the
files they own.
"""

load("//py/private:import_dirs_info.bzl", "ImportDirsInfo", "get_import_dirs")
load("//py/private:pth.bzl", "dep_import_dirs", "own_import_dirs", "own_import_paths")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo")

def _own_files(target):
    info = target[RulesPythonPyInfo]
    files = [
        f
        for field in ("direct_original_sources", "direct_pyi_files")
        for f in (getattr(info, field, None) or depset()).to_list()
    ]

    # py_proto_library has no direct sources; its outputs are the generated
    # modules.
    return files or target[DefaultInfo].files.to_list()

def _foreign_import_dirs_aspect_impl(target, ctx):
    # A rules_py target that also emits `@rules_python`'s `PyInfo` (under
    # --emit_rules_python_providers) already returns its own.
    if ImportDirsInfo in target:
        return []

    files = _own_files(target)
    imports = getattr(ctx.rule.attr, "imports", None)
    if imports != None:
        import_paths = own_import_paths(imports, ctx.workspace_name, ctx.label)
    else:
        import_paths = target[RulesPythonPyInfo].imports.to_list() + [ctx.workspace_name]

    # Each repository root is on the path, and generated files can belong to
    # another repository than the target, as a proto_library's do.
    import_paths += [f.owner.repo_name for f in files if f.owner and f.owner.repo_name]

    deps = getattr(ctx.rule.attr, "deps", []) + getattr(ctx.rule.attr, "pyi_deps", [])
    dep_dirs = depset(transitive = [get_import_dirs(dep) for dep in deps])
    import_dirs = own_import_dirs(import_paths, files, ctx.workspace_name)
    if imports:
        import_dirs += dep_import_dirs(import_paths[:len(imports)], deps, ctx.workspace_name)
    return [ImportDirsInfo(
        import_dirs = depset(direct = import_dirs, transitive = [dep_dirs]),
        # @rules_python merges pyi_deps' import roots into `imports`.
        pyi_import_dirs = depset(),
    )]

foreign_import_dirs_aspect = aspect(
    implementation = _foreign_import_dirs_aspect_impl,
    doc = "Computes `ImportDirsInfo` for targets carrying only `@rules_python`'s `PyInfo`.",
    attr_aspects = ["deps", "pyi_deps"],
    # rules_py targets return their own ImportDirsInfo, and their deps
    # attributes apply this aspect themselves.
    required_providers = [[RulesPythonPyInfo]],
)
