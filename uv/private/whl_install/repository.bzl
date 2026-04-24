"""

Wheel installation repos are actually a bit tricky because this is where we go
from wheel files to a filegroup/py_library. That means we have to perform
platform wheel selection here as well as invoking the installation action to
produce a filegroup/TreeArtifact.

"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load("//uv/private/pprint:defs.bzl", "pprint")

def indent(text, space = " "):
    return "\n".join(["{}{}".format(space, l) for l in text.splitlines()])

def _format_arms(d):
    content = ["        \"{}\": \"{}\"".format(k, v) for k, v in d.items()]
    content = ",\n".join(content)
    return "{\n" + content + "\n   }"

def select_key(triple):
    """Force (triple, target) pairs into a orderable form.

    In order to impose _sequential_ selection on whl arms, we need to impose an
    ordering on platform triples. The way we do this is by coercing "platform
    triples" into:

    - The interpreter (major, minor) pair which  is orderable
    - _assuming_ that platform versions are lexically orderable
    - _assuming_ that ABI is effectively irrelevant to ordering

    This allows us to produce a tuple which will sort roughly according to the
    desired preference order among wheels which COULD be compatible with the
    same platform.

    """

    python, platform, abi = triple

    py_major = int(python[2])
    py_minor = int(python[3:]) if python[3:] else 0
    py = (py_major, py_minor)

    # FIXME: It'd be WAY better if we could enforce a stronger order here
    platform = platform.split("_")
    if platform[0] in ["manylinux", "musllinux", "macosx"]:
        platform = (int(platform[1]), int(platform[2]))
    else:
        platform = (0, 0)

    # Build a key for the ABI.
    #
    # We want to prefer the most specific (eg. cp312t) build over a more generic
    # build (cp312). In order to achieve this, we check the ABI string for
    # specific feature flags and we set those flags to 1 rather than 0 before
    # including them in the sorting key.
    d = 1 if "d" in abi else 0
    m = 1 if "m" in abi else 0
    t = 1 if "t" in abi else 0
    u = 1 if "u" in abi else 0

    flags = (d + m + t + u)
    abi = (flags, d, m, t, u, abi)

    return (py, platform, abi)

def _platform_constraint_labels(canonical_platform):
    """Maps a canonical platform string to Bazel constraint value labels.

    Args:
        canonical_platform: A canonical platform string (e.g. "linux_aarch64").

    Returns:
        A tuple (os_constraint, cpu_constraint) of Bazel constraint value labels.
    """
    parts = canonical_platform.split("_", 1)
    os_name = parts[0]
    cpu = parts[1] if len(parts) > 1 else ""

    os_constraint = {
        "linux": "@platforms//os:linux",
        "macos": "@platforms//os:macos",
        "windows": "@platforms//os:windows",
    }.get(os_name)

    cpu_constraint = {
        "aarch64": "@platforms//cpu:aarch64",
        "x86_64": "@platforms//cpu:x86_64",
        "arm64": "@platforms//cpu:aarch64",
    }.get(cpu)

    return (os_constraint, cpu_constraint)

def _canonical_platforms_from_wheel_name(wheel_name):
    """Maps a wheel filename to its canonical target platform strings.

    A single wheel may be compatible with multiple platforms (e.g. macOS
    universal2 wheels work on both aarch64 and x86_64).

    Args:
        wheel_name: The filename of the wheel.

    Returns:
        A list of canonical platform strings (e.g. ["linux_aarch64"]) or
        an empty list for pure-Python wheels.
    """
    parsed = parse_whl_name(wheel_name)
    platforms = []
    for platform_tag in parsed.platform_tags:
        if platform_tag == "any":
            continue
        if platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_"):
            for arch in ["aarch64", "x86_64", "armv7l", "ppc64le", "s390x", "riscv64"]:
                if platform_tag.endswith("_" + arch):
                    canonical = "linux_" + arch
                    if canonical not in platforms:
                        platforms.append(canonical)
        if platform_tag.startswith("macosx_"):
            if "universal2" in platform_tag:
                for canonical in ["macos_aarch64", "macos_x86_64"]:
                    if canonical not in platforms:
                        platforms.append(canonical)
            elif "arm64" in platform_tag:
                canonical = "macos_aarch64"
                if canonical not in platforms:
                    platforms.append(canonical)
            elif "x86_64" in platform_tag:
                canonical = "macos_x86_64"
                if canonical not in platforms:
                    platforms.append(canonical)
        if platform_tag == "win_amd64":
            canonical = "windows_x86_64"
            if canonical not in platforms:
                platforms.append(canonical)
        if platform_tag == "win_arm64":
            canonical = "windows_arm64"
            if canonical not in platforms:
                platforms.append(canonical)
    return platforms

def sort_select_arms(arms):
    pairs = sorted(arms.items(), key = lambda kv: select_key(kv[0]), reverse = True)
    return {a: b for a, b in pairs}

def _whl_install_impl(repository_ctx):
    """Selects a compatible wheel for the host platform and defines its installation.

    This rule takes a dictionary of available pre-built wheels and an optional
    wheel built from source (`sbuild`). It is responsible for generating the
    logic to select the single, most appropriate wheel for the current target
    platform.

    Note: This rule implicitly depends on //uv/private/constraints/platform:macro.bzl
    to ensure regeneration when platform constraint mappings change.

    It generates a `BUILD.bazel` file that:
    1.  Uses a custom `select_chain` rule to create a sequence of `select`
        statements. This chain checks the current platform against the
        compatibility triples of the available wheels (using the `config_setting`s
        generated by `configurations_hub`) and picks the first, most specific match.
    2.  If an `sbuild` target is provided, it is used as the default fallback in
        the selection chain, for when no pre-built wheel is compatible.
    3.  Feeds the selected wheel file into a `whl_install` build rule, which is
        responsible for unpacking the wheel into a directory.
    4.  Provides a final `install` alias that represents the installed content of
        the chosen wheel.

    Args:
        repository_ctx: The repository context.
    """
    prebuilds = json.decode(repository_ctx.attr.whls)

    select_arms = {}
    _ = repository_ctx.path(Label("//uv/private/constraints/platform:macro.bzl"))

    content = [
        "load(\"@aspect_rules_py//py:defs.bzl\", \"py_library\")",
        "load(\"@aspect_rules_py//uv/private/whl_install:defs.bzl\", \"select_chain\")",
        "load(\"@aspect_rules_py//uv/private/whl_install:rule.bzl\", \"whl_install\")",
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for whl, target in prebuilds.items():
        parsed = parse_whl_name(whl)

        # FIXME: Make it impossible to generate absurd combinations such as cp212-none-cp312 with unsatisfiable version specs.
        for python_tag in parsed.python_tags:
            if not supported_python(python_tag):
                continue

            for platform_tag in parsed.platform_tags:
                if not supported_platform(platform_tag):
                    continue

                for abi_tag in parsed.abi_tags:
                    select_arms[(python_tag, platform_tag, abi_tag)] = target

    select_arms = sort_select_arms(select_arms)

    # FIXME: Insert the sbuild if it exists with an sbuild config flag as the
    # first condition so that the user can force the build to use _only_ sbuilds
    # if available (or transition a target to mandate sbuild).

    select_arms = {
        "@aspect_rules_py_pip_configurations//:{}-{}-{}".format(*k): v
        for k, v in select_arms.items()
    }

    if repository_ctx.attr.sbuild:
        select_arms = select_arms | {
            "//conditions:default": str(repository_ctx.attr.sbuild),
        }

    else:
        content.append("""
py_library(
    name = "_no_sbuild",
    srcs = [],
    deps = [],
    imports = [],
    visibility = ["//visibility:private"],
)
""")
        select_arms = select_arms | {
            "//conditions:default": ":_no_sbuild",
        }

    if not prebuilds and not repository_ctx.attr.sbuild:
        content.append("""
py_library(
    name = "install",
    srcs = [],
    deps = [],
    imports = [],
    visibility = ["//visibility:public"],
)
""")
        repository_ctx.file("BUILD.bazel", content = "\n".join(content))
        return

    if prebuilds:
        gazelle_index_whl = prebuilds.values()[0]  # Effectively random choice :shrug:
    elif repository_ctx.attr.sbuild:
        gazelle_index_whl = repository_ctx.attr.sbuild
    else:
        fail("Cannot identify a wheel or sbuild of {} to analyze for Gazelle indexing\n{}".format(repository_ctx.name, pprint(repository_ctx.attr)))

    content.append(
        """
select_chain(
   name = "whl",
   arms = {arms},
   visibility = ["//visibility:private"],
)

filegroup(
    name = "gazelle_index_whl",
    srcs = {index_whl},
    visibility = ["//visibility:public"],
)

py_library(
    name = "whl_lib",
    srcs = [
        ":whl"
    ],
    data = [
    ],
    visibility = ["//visibility:private"],
)
""".format(
            arms = _format_arms(select_arms),
            index_whl = indent(pprint([str(gazelle_index_whl)]), " " * 4).lstrip(),
        ),
    )

    post_install_patches = json.decode(repository_ctx.attr.post_install_patches) if repository_ctx.attr.post_install_patches else []
    post_install_patch_strip = repository_ctx.attr.post_install_patch_strip

    extra_deps = json.decode(repository_ctx.attr.extra_deps) if repository_ctx.attr.extra_deps else []
    extra_data = json.decode(repository_ctx.attr.extra_data) if repository_ctx.attr.extra_data else []

    compile_pyc_select = """select({
        "@aspect_rules_py//uv/private/pyc:is_precompile": True,
        "//conditions:default": False,
    })"""

    pyc_invalidation_mode_select = """select({
        "@aspect_rules_py//uv/private/pyc:is_unchecked_hash": "unchecked-hash",
        "@aspect_rules_py//uv/private/pyc:is_timestamp": "timestamp",
        "//conditions:default": "checked-hash",
    })"""

    install_attrs_base = """
    compile_pyc = {compile_pyc},
    pyc_invalidation_mode = {pyc_invalidation_mode},""".format(
        compile_pyc = compile_pyc_select,
        pyc_invalidation_mode = pyc_invalidation_mode_select,
    )

    if post_install_patches:
        install_attrs_base += """
    patches = {patches},
    patch_strip = {strip},""".format(
            patches = repr(post_install_patches),
            strip = post_install_patch_strip,
        )

    install_attrs = "    src = \":whl\",\n" + install_attrs_base

    content.append(
        """
whl_install(
    name = "actual_install",
{attrs}
    visibility = ["//visibility:private"],
)""".format(attrs = install_attrs),
    )

    platform_wheels = {}
    for whl_name, target in prebuilds.items():
        canonicals = _canonical_platforms_from_wheel_name(whl_name)
        if canonicals:
            for canonical in canonicals:
                if canonical not in platform_wheels:
                    platform_wheels[canonical] = target
        elif "any" not in platform_wheels:
            platform_wheels["any"] = target

    target_platforms = []
    if repository_ctx.attr.target_platforms:
        target_platforms = json.decode(repository_ctx.attr.target_platforms)

    # Pure-python wheels (platform_tag == "any") are compatible with all target platforms.
    # Create per-platform install aliases so that the :install select works.
    if "any" in platform_wheels:
        any_target = platform_wheels["any"]
        for platform in target_platforms:
            if platform != "any" and platform not in platform_wheels:
                platform_wheels[platform] = any_target

    for canonical, target in platform_wheels.items():
        alias_name = "wheel_{}".format(canonical)
        content.append("""
alias(
    name = "{name}",
    actual = "{target}",
    visibility = ["//visibility:public"],
)
""".format(name = alias_name, target = target))

    for canonical, target in platform_wheels.items():
        install_name = "actual_install_{}".format(canonical)
        content.append("""
whl_install(
    name = "{name}",
    src = ":wheel_{canonical}",
{attrs}
    visibility = ["//visibility:private"],
)

alias(
    name = "install_{canonical}",
    actual = ":{name}",
    visibility = ["//visibility:public"],
)
""".format(
            name = install_name,
            canonical = canonical,
            attrs = install_attrs_base,
        ))

    if target_platforms:
        platform_arms = {}
        default_arm = None
        for platform in target_platforms:
            if platform == "any":
                default_arm = ":install_any"
                continue
            os_constraint, cpu_constraint = _platform_constraint_labels(platform)
            if not os_constraint or not cpu_constraint:
                continue
            config_name = "_platform_{}".format(platform)
            content.append("""
config_setting(
    name = "{name}",
    constraint_values = [
        "{os}",
        "{cpu}",
    ],
    visibility = ["//visibility:private"],
)
""".format(
                name = config_name,
                os = os_constraint,
                cpu = cpu_constraint,
            ))
            platform_arms[":" + config_name] = ":install_{}".format(platform)

        if "any" in platform_wheels and not default_arm:
            default_arm = ":install_any"

        if default_arm:
            platform_arms["//conditions:default"] = default_arm

        select_arms_str = "{\n"
        for config, target in platform_arms.items():
            select_arms_str += '        "{}": "{}",\n'.format(config, target)
        select_arms_str += "    }"

        if extra_deps or extra_data:
            content.append(
                """
py_library(
    name = "install",
    srcs = [],
    deps = [select({arms})] + {extra_deps},
    data = {extra_data},
    visibility = ["//visibility:public"],
)
""".format(
                    arms = select_arms_str,
                    extra_deps = repr(extra_deps),
                    extra_data = repr(extra_data),
                ),
            )
        else:
            content.append(
                """
alias(
    name = "install",
    actual = select({arms}),
    visibility = ["//visibility:public"],
)
""".format(arms = select_arms_str),
            )
    elif extra_deps or extra_data:
        content.append(
            """
py_library(
    name = "install",
    srcs = [],
    deps = [
        select({{
            "@aspect_rules_py//uv/private/constraints:libs_are_libs": ":actual_install",
            "@aspect_rules_py//uv/private/constraints:libs_are_whls": ":whl_lib",
        }}),
    ] + {extra_deps},
    data = {extra_data},
    visibility = ["//visibility:public"],
)
""".format(
                extra_deps = repr(extra_deps),
                extra_data = repr(extra_data),
            ),
        )
    else:
        content.append(
            """\
alias(
    name = "install",
    actual = select({
        "@aspect_rules_py//uv/private/constraints:libs_are_libs": ":actual_install",
        "@aspect_rules_py//uv/private/constraints:libs_are_whls": ":whl_lib",
    }),
    visibility = ["//visibility:public"],
)
""",
        )

    repository_ctx.file("BUILD.bazel", content = "\n".join(content))

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return repository_ctx.repo_metadata(reproducible = True)

whl_install = repository_rule(
    implementation = _whl_install_impl,
    attrs = {
        "whls": attr.string(),
        "sbuild": attr.label(),
        "post_install_patches": attr.string(default = ""),
        "post_install_patch_strip": attr.int(default = 0),
        "extra_deps": attr.string(default = ""),
        "extra_data": attr.string(default = ""),
        "target_platforms": attr.string(
            default = "",
            doc = "JSON-encoded list of canonical target platforms. When present, :install uses platform-based select.",
        ),
        "_config_version": attr.int(default = 2),
    },
)
