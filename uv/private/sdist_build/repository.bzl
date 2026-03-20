"""
Repository rule backing sdist_build repos.

Consumes a given src (.tar.gz or other artifact) and deps. Runs a configure
tool to inspect the archive, then generates a BUILD.bazel that uses the
appropriate backend-specific build rule (e.g. setuptools_whl, maturin_whl).
"""

load("//uv/private:normalize_name.bzl", "normalize_name")

# --- Configure tool invocation ---

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
    script = repository_ctx.attr.configure_script
    interpreter = repository_ctx.attr.configure_interpreter

    if not script:
        return None

    context_path = _write_context_file(repository_ctx)
    script_path = repository_ctx.path(script)

    if interpreter:
        cmd = [repository_ctx.path(interpreter), script_path, archive_path, context_path]
    else:
        cmd = [script_path, archive_path, context_path]

    result = repository_ctx.execute(cmd, timeout = 30)
    if result.return_code != 0:
        # buildifier: disable=print
        print("WARNING: sdist configure tool failed for {} (exit {}): {}".format(
            repository_ctx.name,
            result.return_code,
            result.stderr,
        ))
        return None

    return json.decode(result.stdout)

# --- Dep resolution ---

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

def _log_build_dep_info(repository_ctx, inspection):
    """Log informational messages about discovered build dependencies."""
    if not inspection:
        return

    build_requires = inspection.get("build_requires", [])
    inferred = inspection.get("inferred_build_requires", [])
    extra = inspection.get("extra_deps", [])

    if build_requires or inferred:
        all_names = sorted(set(build_requires + inferred))

        # buildifier: disable=print
        print("Build deps discovered for {}: {}{}".format(
            repository_ctx.name,
            ", ".join(all_names),
            " (auto-wiring: {})".format(", ".join(extra)) if extra else "",
        ))

# --- Repository rule implementation ---

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
        archive_path = repository_ctx.path(repository_ctx.attr.src)
        inspection = _run_configure_tool(repository_ctx, archive_path)

        if inspection != None:
            # If the tool provided complete build file content, use it directly.
            build_file_content = inspection.get("build_file_content")
            if build_file_content:
                _log_build_dep_info(repository_ctx, inspection)
                repository_ctx.file("BUILD.bazel", content = build_file_content)
                return

            is_native = inspection["is_native"]
            if is_native:
                # buildifier: disable=print
                print("Detected native sources in {}: {} file(s)".format(
                    repository_ctx.name,
                    len(inspection.get("native_files", [])),
                ))
        else:
            # No tool or tool failed — assume pure-Python. sdist_build
            # validates -none-any so a wrong guess fails loudly at build time.
            # buildifier: disable=print
            print("WARNING: Could not inspect sdist for {}; assuming pure-Python".format(
                repository_ctx.name,
            ))
            is_native = False
    else:
        is_native = is_native_override == "true"

    # Resolve additional deps discovered by the configure tool
    extra_dep_labels = _resolve_extra_deps(repository_ctx, inspection)
    _log_build_dep_info(repository_ctx, inspection)

    # Merge explicit deps with auto-discovered deps
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
load("@aspect_rules_py//uv/private/setuptools_whl:rule.bzl", "{rule}")
load("@aspect_rules_py//py/unstable:defs.bzl", "py_venv_binary")

py_venv_binary(
    name = "build_tool",
    main = "@aspect_rules_py//uv/private/setuptools_whl:build_helper.py",
    srcs = ["@aspect_rules_py//uv/private/setuptools_whl:build_helper.py"],
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
        rule = "sdist_native_build" if is_native else "sdist_build",
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
        "configure_script": attr.label(
            mandatory = False,
            allow_single_file = True,
            doc = "Label to an sdist configure tool script/binary. " +
                  "See //uv/private/sdist_configure:defs.bzl for the contract.",
        ),
        "configure_interpreter": attr.label(
            mandatory = False,
            doc = "Label to a Python interpreter for running the configure script. " +
                  "Not needed for compiled configure tools.",
        ),
        "version": attr.string(),
        "pre_build_patches": attr.label_list(default = []),
        "pre_build_patch_strip": attr.int(default = 0),
    },
)
