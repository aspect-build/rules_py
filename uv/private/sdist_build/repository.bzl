"""
Repository rule backing sdist_build repos.

Consumes a given src (.tar.gz or other artifact) and deps. Runs a configure
tool to inspect the archive, then generates a BUILD.bazel that uses the
appropriate backend-specific build rule (e.g. pep517_whl, maturin_whl).
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load(":attrs.bzl", "validate_build_attrs")

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
        if repository_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
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

# --- Archive path resolution ---

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

    # src_path doesn't exist — it's likely `<pkg>/file` from a filegroup.
    # Scan the parent directory for an archive file.
    parent = src_path.dirname
    if parent.exists:
        for child in parent.readdir():
            name = child.basename
            if name in ("BUILD", "BUILD.bazel"):
                continue
            if name.endswith(".tar.gz") or name.endswith(".tar.bz2") or name.endswith(".tar.xz") or name.endswith(".zip") or name.endswith(".tar"):
                return child

    if repository_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
        # buildifier: disable=print
        print("WARNING: Could not resolve archive path from src label for {}".format(
            repository_ctx.name,
        ))
    return None

# --- Repository rule implementation ---

def _sdist_build_impl(repository_ctx):
    """Prepares a repository for building a wheel from a source distribution (sdist).

    A configure tool may inspect the sdist archive and return:
    - `build_file_content`: used verbatim as the BUILD.bazel
    - `is_native` + `extra_deps`: used to generate a standard build file
      with the appropriate rule and resolved dependencies

    An explicit `is_native` selects the generated rule while preserving
    configure-discovered deps. It conflicts with complete `build_file_content`,
    which is otherwise used verbatim.

    See //uv/private/sdist_configure:defs.bzl for the tool contract.

    Args:
        repository_ctx: The repository context.
    """

    is_native_override = repository_ctx.attr.is_native
    archive_path = _resolve_archive_path(repository_ctx)
    inspection = _run_configure_tool(repository_ctx, archive_path) if archive_path else None
    build_file_content = inspection.get("build_file_content") if inspection else None

    if build_file_content and is_native_override != "auto":
        fail("sdist_build for '{}': explicit `is_native = \"{}\"` requests a generated `pep517_*whl(...)` call, but the configure tool returned complete `build_file_content`; remove the native annotation, or have the configure tool select the build rule.".format(repository_ctx.name, is_native_override))

    if is_native_override == "auto":
        if inspection != None:
            # If the tool provided complete build file content, use it directly.
            if build_file_content:
                validate_build_attrs(
                    console_scripts = [],
                    resource_set = repository_ctx.attr.resource_set,
                    env = repository_ctx.attr.extra_env,
                    error = "sdist_build for '{}': the configure tool returned complete `build_file_content`, which bypasses the generated `pep517_*whl(...)` call, so these attributes cannot be applied: {{}}. Drop them from the override, or have the configure tool set them in its own `build_file_content`.".format(repository_ctx.name),
                    monitor_memory = repository_ctx.attr.monitor_memory,
                    pre_build_patches = repository_ctx.attr.pre_build_patches,
                    pre_build_patch_strip = repository_ctx.attr.pre_build_patch_strip,
                    supported = [
                        "pre_build_patches",
                        "pre_build_patch_strip",
                    ],
                    toolchains = repository_ctx.attr.extra_toolchains,
                )
                repository_ctx.file("BUILD.bazel", content = build_file_content)
                return

            is_native = inspection["is_native"]
            if is_native and repository_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
                # buildifier: disable=print
                print("Detected native sources in {}: {} file(s)".format(
                    repository_ctx.name,
                    len(inspection.get("native_files", [])),
                ))
        else:
            # No tool or tool failed — assume pure-Python. sdist_build
            # validates -none-any so a wrong guess fails loudly at build time.
            if repository_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
                # buildifier: disable=print
                print("WARNING: Could not inspect sdist for {}; assuming pure-Python".format(
                    repository_ctx.name,
                ))
            is_native = False
    else:
        is_native = is_native_override == "true"

    if not is_native:
        validate_build_attrs(
            console_scripts = [],
            resource_set = repository_ctx.attr.resource_set,
            env = repository_ctx.attr.extra_env,
            error = "sdist_build for '{}': the generated pure-Python `pep517_whl(...)` call cannot apply these native-build attributes: {{}}. Remove them, or configure this source distribution as native.".format(repository_ctx.name),
            monitor_memory = repository_ctx.attr.monitor_memory,
            pre_build_patches = repository_ctx.attr.pre_build_patches,
            pre_build_patch_strip = repository_ctx.attr.pre_build_patch_strip,
            supported = [
                "monitor_memory",
                "pre_build_patches",
                "pre_build_patch_strip",
                "resource_set",
            ],
            toolchains = repository_ctx.attr.extra_toolchains,
        )

    # Resolve additional deps discovered by the configure tool
    extra_dep_labels = _resolve_extra_deps(repository_ctx, inspection)

    # TODO: When the configure tool didn't run or failed, we may want to
    # conservatively add setuptools + wheel as fallback build deps. For now
    # we rely on the configure tool succeeding.

    # Merge explicit deps with auto-discovered deps
    all_deps = [str(d) for d in repository_ctx.attr.deps] + extra_dep_labels

    monitor_memory_attr = ""
    if repository_ctx.attr.monitor_memory:
        all_deps = [
            "@aspect_rules_py//uv/private/pep517_whl:memory_monitor",
        ] + all_deps
        monitor_memory_attr = "\n    monitor_memory = True,"

    pre_build_patches = repository_ctx.attr.pre_build_patches
    patch_attrs = ""
    if pre_build_patches:
        patch_attrs = """
    pre_build_patches = {patches},
    pre_build_patch_strip = {strip},""".format(
            patches = repr([str(it) for it in pre_build_patches]),
            strip = repository_ctx.attr.pre_build_patch_strip,
        )

    # For native builds, emit a baked-in CC toolchain + CC/CXX/AR/LD/STRIP
    # env block. Targets in `toolchains` expose `TemplateVariableInfo`;
    # the env values below are make-variable references resolved at
    # action analysis time.
    #
    # CXX starts at $(CC); pep517_native_whl replaces it with a matching
    # same-directory clang++ / g++ from the selected toolchain when present.
    #
    # `extra_toolchains` and `extra_env` augment (do not replace) the
    # defaults — set via `uv.override_package(toolchains = [...],
    # env = {...})` to layer JDK / Rust / etc. plumbing on top.
    toolchain_attrs = ""
    if is_native:
        toolchains = [
            "@bazel_tools//tools/cpp:current_cc_toolchain",
        ] + list(repository_ctx.attr.extra_toolchains)
        env = {
            "AR": "$(AR)",
            "CC": "$(CC)",
            "CXX": "$(CC)",
            "LD": "$(LD)",
            "STRIP": "$(STRIP)",
        }
        env.update(repository_ctx.attr.extra_env)
        toolchain_attrs = """
    toolchains = [
{toolchains}
    ],
    env = {{
{env}
    }},""".format(
            toolchains = "\n".join(["        \"{}\",".format(t) for t in toolchains]),
            env = "\n".join(["        \"{}\": \"{}\",".format(k, v) for k, v in sorted(env.items())]),
        )

    resource_set_attr = ""
    if repository_ctx.attr.resource_set != "default":
        resource_set_attr = "\n    resource_set = \"{}\",".format(repository_ctx.attr.resource_set)

    # Leave args unset: the pure rule validates anyarch wheels by default,
    # while the native rule defaults to no validation.
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
    version = "{version}",{monitor_memory_attr}{resource_set_attr}{patch_attrs}{toolchain_attrs}
    visibility = ["//visibility:public"],
)

exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""".format(
        src = repository_ctx.attr.src,
        deps = repr(all_deps),
        monitor_memory_attr = monitor_memory_attr,
        rule = "pep517_native_whl" if is_native else "pep517_whl",
        version = repository_ctx.attr.version,
        resource_set_attr = resource_set_attr,
        patch_attrs = patch_attrs,
        toolchain_attrs = toolchain_attrs,
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
        "monitor_memory": attr.bool(
            default = False,
            doc = "Whether to report approximate Linux process-tree RSS for the wheel build.",
        ),
        "resource_set": attr.string(
            default = "default",
            doc = "bazel-lib resource_set name forwarded to the generated pep517_*whl(...) " +
                  "`resource_set` attribute, reserving local RAM/CPU for the wheel build " +
                  "action. Set via `uv.override_package(resource_set = ...)`.",
        ),
        "pre_build_patches": attr.label_list(default = []),
        "pre_build_patch_strip": attr.int(default = 0),
        "extra_toolchains": attr.string_list(
            default = [],
            doc = "Toolchain labels appended to the default CC toolchain in the generated pep517_native_whl(...) `toolchains` list. Set via `uv.override_package(toolchains = [...])`.",
        ),
        "extra_env": attr.string_dict(
            default = {},
            doc = "Environment variables merged into the default CC env dict in the generated pep517_native_whl(...) `env` dict. Values may reference $(VAR) make-variables from any toolchain. Set via `uv.override_package(env = {...})`.",
        ),
    },
)
