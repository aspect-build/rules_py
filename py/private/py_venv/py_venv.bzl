"""Implementation for the py_binary and py_test rules."""

load("@aspect_bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:transitions.bzl", "python_version_transition")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "PyToolInfo", "SHIM_TOOLCHAIN", "VENV_TOOLCHAIN")

VirtualenvInfo = provider(
    doc = """
    Provider used to distinguish venvs from py rules.
    """,
    fields = {
        "home": "Path of the virtualenv",
    },
)

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def _interpreter_flags(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    args = py_toolchain.flags + ctx.attr.interpreter_options

    if hasattr(ctx.file, "main"):
        args.append(
            "\"$(rlocation {})\"".format(to_rlocation_path(ctx, ctx.file.main)),
        )

    args = [it for it in args if it not in ["-I"]]

    return args

# FIXME: This is derived directly from the py_binary.bzl rule and should really
# be a layer on top of it if we can figure out flowing the data around. This is
# PoC quality.

def _py_venv_base_impl(ctx):
    """
    Common venv bits.

    Taking a PyInfo transitive depset and shove all that into a "virtualenv" tree.
    Depended on by the implementation of venv building and venv-based binary building.
    """

    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Note that we HAVE to grab these files from toolchains so that we can swap
    # in prebuild versions in production.
    py_shim = ctx.toolchains[SHIM_TOOLCHAIN]
    venv_tool = ctx.attr._venv[PyToolInfo].bin

    # Check for duplicate virtual dependency names. Those that map to the same resolution target would have been merged by the depset for us.
    virtual_resolution = _py_library.resolve_virtuals(ctx)

    # Note that this adds the workspace root for us (sigh), don't need to add to it
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")
    pth_lines.add_all(imports_depset)

    site_packages_pth_file = ctx.actions.declare_file("{}.pth".format(ctx.attr.name))
    ctx.actions.write(
        output = site_packages_pth_file,
        content = pth_lines,
    )

    env_file = ctx.actions.declare_file("{}.env".format(ctx.attr.name))

    default_env = {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

    ctx.actions.write(
        output = env_file,
        content = "\n".join(_dict_to_exports(default_env)).strip(),
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)

    # Use the runfiles computation logic to figure out the files we need to
    # _build_ the venv. The final venv is these runfiles _plus_ the venv's
    # structures.
    rfs = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
                            py_toolchain.files,
                            srcs_depset,
                        ] + virtual_resolution.srcs + virtual_resolution.runfiles +
                        ([py_toolchain.files] if py_toolchain.runfiles_interpreter else []),
        extra_runfiles_depsets = [
            ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
        ],
    )

    venv_name = ".{}".format(ctx.attr.name)
    venv_dir = ctx.actions.declare_directory(venv_name)

    ctx.actions.run(
        executable = venv_tool,
        arguments = [
            "--location=" + venv_dir.path,
            "--venv-shim=" + py_shim.bin.bin.path,
            "--python=" + to_rlocation_path(ctx, py_toolchain.python) if py_toolchain.runfiles_interpreter else py_toolchain.python.path,
            "--pth-file=" + site_packages_pth_file.path,
            "--env-file=" + env_file.path,
            "--bin-dir=" + ctx.bin_dir.path,
            "--collision-strategy=" + ctx.attr.package_collisions,
            "--venv-name=" + venv_name,
            "--mode=static-copy",
            "--version={}.{}".format(
                py_toolchain.interpreter_version_info.major,
                py_toolchain.interpreter_version_info.minor,
            ),
        ] + (["--debug"] if ctx.attr.debug else []),
        inputs = rfs.merge_all([
            ctx.runfiles(files = [
                site_packages_pth_file,
                env_file,
                venv_tool,
            ] + py_toolchain.files.to_list()),
            py_shim.default_info.default_runfiles,
        ]).files,
        outputs = [
            venv_dir,
        ],
    )

    return venv_dir, rfs.merge_all([
        ctx.runfiles(files = [
            venv_dir,
        ] + py_toolchain.files.to_list()),
        ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
    ])

def _py_venv_rule_impl(ctx):
    """
    A virtualenv implementation the binary of which is a proxy to the Python interpreter of the venv.
    """

    venv_dir, rfs = _py_venv_base_impl(ctx)

    # Now we can generate an entrypoint script wrapping $VENV/bin/python
    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,  # FIXME: Should always be single file
        output = ctx.outputs.executable,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION.strip(),
            "{{INTERPRETER_FLAGS}}": " ".join(_interpreter_flags(ctx)),
            "{{ENTRYPOINT}}": "${VIRTUAL_ENV}/bin/python",
            "{{VENV}}": to_rlocation_path(ctx, venv_dir),
            "{{DEBUG}}": str(ctx.attr.debug).lower(),
        },
        is_executable = True,
    )

    # TODO: Zip output group to allow for bypassing filtering et. all

    return [
        DefaultInfo(
            files = depset([
                ctx.outputs.executable,
                venv_dir,
            ]),
            executable = ctx.outputs.executable,
            runfiles = rfs.merge(
                ctx.runfiles(files = [venv_dir]),
            ),
        ),
        # FIXME: Does not provide PyInfo because venvs are supposed to be terminal artifacts.
        VirtualenvInfo(
            home = venv_dir,
        ),
    ]

def _py_venv_binary_impl(ctx):
    """
    A virtualenv implementation the binary of which is a proxy to the Python interpreter of the venv.
    """

    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Make runfiles to handle direct srcs and deps which we need to bolt on top
    # of the venv
    srcs_depset = _py_library.make_srcs_depset(ctx)
    virtual_resolution = _py_library.resolve_virtuals(ctx)

    # Use the runfiles computation logic to figure out the files we need to
    # _build_ the venv. The final venv is these runfiles _plus_ the venv's
    # structures.
    rfs = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            py_toolchain.files,
            srcs_depset,
        ] + virtual_resolution.srcs + virtual_resolution.runfiles,
    )

    if not ctx.attr.venv:
        venv_dir, venv_rfs = _py_venv_base_impl(ctx)

    else:
        venv_dir = ctx.attr.venv[VirtualenvInfo].home
        venv_rfs = ctx.attr.venv[DefaultInfo].default_runfiles

    rfs = rfs.merge(venv_rfs)

    # Now we can generate an entrypoint script wrapping $VENV/bin/python
    ctx.actions.expand_template(
        template = ctx.file._bin_tmpl,  # FIXME: Should always be single file
        output = ctx.outputs.executable,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION.strip(),
            "{{INTERPRETER_FLAGS}}": " ".join(_interpreter_flags(ctx)),
            "{{VENV}}": to_rlocation_path(ctx, venv_dir),
            "{{DEBUG}}": str(ctx.attr.debug).lower(),
        },
        is_executable = True,
    )

    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    return [
        DefaultInfo(
            files = depset([
                ctx.outputs.executable,
            ]),
            executable = ctx.outputs.executable,
            runfiles = rfs,
        ),
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = getattr(ctx.attr, "env_inherit", []),
        ),
    ]

_attrs = dict({
    "env": attr.string_dict(
        doc = "Environment variables to set when running the binary.",
        default = {},
    ),
    "python_version": attr.string(
        doc = """Whether to build this target and its transitive deps for a specific python version.""",
    ),
    "package_collisions": attr.string(
        doc = """The action that should be taken when a symlink collision is encountered when creating the venv.
A collision can occur when multiple packages providing the same file are installed into the venv. The possible values are:

* "error": When conflicting symlinks are found, an error is reported and venv creation halts.
* "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues.
* "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.
        """,
        default = "error",
        values = ["error", "warning", "ignore"],
    ),
    "interpreter_options": attr.string_list(
        doc = "Additional options to pass to the Python interpreter.",
        default = [],
    ),
    # NB: this is read by _resolve_toolchain in py_semantics.
    "_interpreter_version_flag": attr.label(
        default = "//py:interpreter_version",
    ),
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private/py_venv:entrypoint.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    "_venv": attr.label(
        default = "//py/private/toolchain:resolved_venv_toolchain",
        cfg = "exec",
    ),
    "debug": attr.bool(
        default = False,
    ),
})

_attrs.update(**_py_library.attrs)

_binary_attrs = dict({
    "main": attr.label(
        doc = "Script to execute with the Python interpreter.",
        allow_single_file = True,
        mandatory = True,
    ),
    "venv": attr.label(
        doc = "A virtualenv; if provided all 3rdparty deps are assumed to come via the venv.",
        providers = [[VirtualenvInfo]],
    ),
    "_bin_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private/py_venv:entrypoint.tmpl.sh",
    ),
})

_test_attrs = dict({
    "env_inherit": attr.string_list(
        doc = "Specifies additional environment variables to inherit from the external environment when the test is executed by bazel test.",
        default = [],
    ),
    # Magic attribute to make coverage --combined_report flag work.
    # There's no docs about this.
    # See https://github.com/bazelbuild/bazel/blob/fde4b67009d377a3543a3dc8481147307bd37d36/tools/test/collect_coverage.sh#L186-L194
    # NB: rules_python ALSO includes this attribute on the py_binary rule, but we think that's a mistake.
    # see https://github.com/aspect-build/rules_py/pull/520#pullrequestreview-25790761972
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
    ),
})

py_venv_base = struct(
    attrs = _attrs,
    binary_attrs = _binary_attrs,
    test_attrs = _test_attrs,
    toolchains = [
        PY_TOOLCHAIN,
        SHIM_TOOLCHAIN,
        VENV_TOOLCHAIN,
    ],
    cfg = python_version_transition,
)

_py_venv = rule(
    doc = """Build a Python virtual environment and execute its interpreter.""",
    implementation = _py_venv_rule_impl,
    attrs = py_venv_base.attrs,
    toolchains = py_venv_base.toolchains,
    executable = True,
    cfg = py_venv_base.cfg,
)

def _wrap_with_debug(rule):
    def helper(**kwargs):
        kwargs["debug"] = select({Label(":debug_venv_setting"): True, "//conditions:default": False})
        return rule(**kwargs)

    return helper

_py_venv_binary = rule(
    doc = """Run a Python program under Bazel using a virtualenv.""",
    implementation = _py_venv_binary_impl,
    attrs = py_venv_base.attrs | py_venv_base.binary_attrs,
    toolchains = py_venv_base.toolchains,
    executable = True,
    cfg = py_venv_base.cfg,
)

_py_venv_test = rule(
    doc = """Run a Python program under Bazel using a virtualenv.""",
    implementation = _py_venv_binary_impl,
    attrs = py_venv_base.attrs | py_venv_base.binary_attrs | py_venv_base.test_attrs,
    toolchains = py_venv_base.toolchains,
    test = True,
    cfg = py_venv_base.cfg,
)

py_venv = _wrap_with_debug(_py_venv)
py_venv_binary = _wrap_with_debug(_py_venv_binary)
py_venv_test = _wrap_with_debug(_py_venv_test)

def py_venv_link(venv_name = None, srcs = [], **kwargs):
    """Build a Python virtual environment and produce a script to link it into the build directory."""

    # Note that the binary is already wrapped with debug
    link_script = str(Label("//py/private/py_venv:link.py"))
    kwargs["debug"] = select({Label(":debug_venv_setting"): True, "//conditions:default": False})
    py_venv_binary(
        args = [] + (["--name=" + venv_name] if venv_name else []),
        main = link_script,
        srcs = srcs + [link_script],
        **kwargs
    )
