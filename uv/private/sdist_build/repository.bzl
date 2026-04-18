"""
Repository rule backing sdist_build repos.

Consumes a given src (.tar.gz or other artifact) and deps. Runs a configure
tool to inspect the archive, then generates a BUILD.bazel that uses the
appropriate backend-specific build rule (e.g. pep517_whl, maturin_whl).
"""

load("//uv/private:normalize_name.bzl", "normalize_name")


def _write_context_file(repository_ctx):
    """Write the context JSON file that the configure tool reads.

    See //uv/private/sdist_configure:defs.bzl for the schema.
    """
    available_deps = {}
    if repository_ctx.attr.available_deps:
        available_deps = json.decode(repository_ctx.attr.available_deps)

    context = {
        "src": str(repository_ctx.attr.src),
        "version": repository_ctx.attr.version,
        "deps": [str(d) for d in repository_ctx.attr.deps],
        "available_deps": available_deps,
        "pre_build_patches": [str(p) for p in repository_ctx.attr.pre_build_patches],
        "pre_build_patch_strip": repository_ctx.attr.pre_build_patch_strip,
    }

    context_path = repository_ctx.path("_configure_context.json")
    repository_ctx.file("_configure_context.json", content = json.encode(context))
    return context_path

def _run_configure_tool(repository_ctx, archive_path):
    """Run the sdist configure tool and return its parsed JSON output.

    See //uv/private/sdist_configure:defs.bzl for the tool contract.

    Returns a dict on success, or None on failure.
    """
    configure_command = repository_ctx.attr.configure_command

    if not configure_command:
        return None

    context_path = _write_context_file(repository_ctx)

    cmd = []
    for arg in configure_command:
        loc_start = "$(location "
        if arg.startswith(loc_start):
            close = arg.rfind(")")
            label = Label(arg[len(loc_start):close])
            repository_ctx.watch(label)
            cmd.append(str(repository_ctx.path(label)) + arg[close + 1:])
        else:
            cmd.append(arg)
    cmd.extend([str(archive_path), str(context_path)])

    result = repository_ctx.execute(cmd, timeout = 30)
    if result.return_code != 0:
        print("WARNING: sdist configure tool failed for {} (exit {}): {}".format(
            repository_ctx.name,
            result.return_code,
            result.stderr,
        ))
        return None

    return json.decode(result.stdout)

def _resolve_extra_deps(repository_ctx, inspection):
    """Resolve extra_deps from the configure tool output into label strings.

    Returns a list of label strings. Calls fail() if a dep cannot be resolved.
    """
    if not inspection:
        return []
    extra_dep_names = inspection.get("extra_deps", [])
    if not extra_dep_names:
        return []

    available_deps = {}
    if repository_ctx.attr.available_deps:
        available_deps = json.decode(repository_ctx.attr.available_deps)

    resolved = []
    unresolvable = []
    for name in extra_dep_names:
        normalized = normalize_name(name)
        label = available_deps.get(normalized)
        if label:
            resolved.append(label)
        else:
            unresolvable.append(normalized)

    if unresolvable:
        fail(
            "sdist configure tool for {} reported build deps that are not in " +
            "the lockfile: {}. Add these packages to your lockfile or provide " +
            "them via uv.unstable_annotate_packages().".format(
                repository_ctx.name,
                ", ".join(unresolvable),
            ),
        )

    return resolved

def _resolve_archive_path(repository_ctx):
    """Resolve the src label to an actual archive file path.

    The src label typically points at an http_file filegroup (e.g.
    @sdist__foo//file) whose default target is `:file`, a filegroup wrapping
    the downloaded archive. repository_ctx.path() on that label yields
    `<repo>/file/file` which doesn't exist on disk — the real archive is a
    sibling like `<repo>/file/foo-1.0.tar.gz`. We scan the parent directory
    for archive files.
    """
    src_path = repository_ctx.path(repository_ctx.attr.src)
    if src_path.exists:
        return src_path

    parent = src_path.dirname
    if parent.exists:
        for child in parent.readdir():
            name = child.basename
            if name in ("BUILD", "BUILD.bazel"):
                continue
            if name.endswith(".tar.gz") or name.endswith(".tar.bz2") or name.endswith(".tar.xz") or name.endswith(".zip") or name.endswith(".tar"):
                return child

    print("WARNING: Could not resolve archive path from src label for {}".format(
        repository_ctx.name,
    ))
    return None

def _sdist_build_impl(repository_ctx):
    """Prepares a repository for building a wheel from a source distribution (sdist).

    When `is_native` is "auto" (the default), a configure tool is run to
    inspect the sdist archive. The tool may return:
    - `build_file_content`: used verbatim as the BUILD.bazel
    - `is_native` + `extra_deps`: used to generate a standard build file
      with the appropriate rule and resolved dependencies

    See //uv/private/sdist_configure:defs.bzl for the tool contract.

    Args:
        repository_ctx: The repository context.
    """

    is_native_override = repository_ctx.attr.is_native
    inspection = None

    if is_native_override == "auto":
        archive_path = _resolve_archive_path(repository_ctx)
        inspection = _run_configure_tool(repository_ctx, archive_path) if archive_path else None

        if inspection != None:
            build_file_content = inspection.get("build_file_content")
            if build_file_content:
                repository_ctx.file("BUILD.bazel", content = build_file_content)
                return

            is_native = inspection["is_native"]
            if is_native:
                print("Detected native sources in {}: {} file(s)".format(
                    repository_ctx.name,
                    len(inspection.get("native_files", [])),
                ))
        else:
            print("WARNING: Could not inspect sdist for {}; assuming pure-Python".format(
                repository_ctx.name,
            ))
            is_native = False
    else:
        is_native = is_native_override == "true"

    extra_dep_labels = _resolve_extra_deps(repository_ctx, inspection)

    # TODO: When the configure tool didn't run or failed, we may want to
    # conservatively add setuptools + wheel as fallback build deps. For now
    # we rely on the configure tool succeeding.

    all_deps = [str(d) for d in repository_ctx.attr.deps] + extra_dep_labels

    pre_build_patches = repository_ctx.attr.pre_build_patches
    patch_attrs = ""
    if pre_build_patches:
        patch_attrs = """
    pre_build_patches = {patches},
    pre_build_patch_strip = {strip},""".format(
            patches = repr([str(it) for it in pre_build_patches]),
            strip = repository_ctx.attr.pre_build_patch_strip,
        )

    repository_ctx.file("BUILD.bazel", content = """
load("@aspect_rules_py//uv/private/pep517_whl:rule.bzl", "{rule}")
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(
    name = "build_tool",
    main = "@aspect_rules_py//uv/private/pep517_whl:build_helper.py",
    srcs = ["@aspect_rules_py//uv/private/pep517_whl:build_helper.py"],
    deps = {deps},
)

{rule}(
    name = "whl",
    src = "{src}",
    tool = ":build_tool",
    version = "{version}",
    args = [],{patch_attrs}
    visibility = ["//visibility:public"],
)
""".format(
        src = repository_ctx.attr.src,
        deps = repr(all_deps),
        rule = "pep517_native_whl" if is_native else "pep517_whl",
        version = repository_ctx.attr.version,
        patch_attrs = patch_attrs,
    ))

sdist_build = repository_rule(
    implementation = _sdist_build_impl,
    attrs = {
        "src": attr.label(),
        "deps": attr.label_list(),
        "available_deps": attr.string(
            default = "",
            doc = "JSON-encoded dict mapping normalized package names to install " +
                  "labels. Passed from the uv extension; used to resolve deps " +
                  "discovered by the configure tool.",
        ),
        "is_native": attr.string(default = "auto", values = ["auto", "true", "false"]),
        "configure_command": attr.string_list(
            default = [],
            doc = "Command to run as the sdist configure tool. Each element is " +
                  "either a literal string or a $(location <label>) reference. " +
                  "The archive path and context file are appended as the final " +
                  "two arguments. See //uv/private/sdist_configure:defs.bzl.",
        ),
        "version": attr.string(),
        "pre_build_patches": attr.label_list(default = []),
        "pre_build_patch_strip": attr.int(default = 0),
    },
)
