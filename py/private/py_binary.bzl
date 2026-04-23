"""Implementation for the py_binary and py_test rules."""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(":transitions.bzl", "python_version_transition")

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

# Template for console-script wrappers under <venv>/bin/<name>. A tiny shell
# script that execs the venv's own bin/python with an inline `-c` to import
# the entry point and call it. Keeping this as pure sh (no polyglot) sidesteps
# tokenisation quirks with `$` in strings, and the inline Python is short
# enough that not having a real `__file__` doesn't matter in practice.
# `"$@"` preserves the original argv, while sys.argv[0] is patched so the
# called function sees the script's own name.
_CONSOLE_SCRIPT_TEMPLATE = """\
#!/bin/sh
exec "$(dirname "$0")/python" -c 'import sys; from {module} import {func}; sys.argv[0] = "{name}"; sys.exit({func}())' "$@"
"""

def _resolve_wheel_collisions(ctx, wheels):
    """Walk PyWheelsInfo.wheels to produce merge plans for site-packages AND bin/.

    Two kinds of collision get checked:

    * **Top-level in site-packages.** Multiple wheels claiming the same
      top-level name (e.g. both shipping `foo/__init__.py`). When ALL
      contributing wheels flag the name as a PEP 420 namespace package
      (no `__init__.py` at that level), the collision is benign — skip
      the per-top-level symlink and let the wheel's site-packages fall
      through to `.pth` + `addsitedir`, where Python's namespace
      machinery merges contributions natively. Otherwise, apply the
      `package_collisions` policy.

    * **Console-script name in bin/.** Apply the `package_collisions`
      policy directly — there's no namespace equivalent.

    Policy:
      * "error"   -> fail the analysis
      * "warning" -> print a warning; first-seen wins, rest skipped
      * "ignore"  -> first-seen wins silently

    Returns:
      top_level_to_site_pkgs: dict {top_level_name: site_packages_rfpath}
      fully_covered_site_pkgs: set (as dict) of site-packages paths whose
          declared top-levels ALL ended up claimed by them — safe to drop
          from the .pth fallback.
      console_scripts_map: dict {script_name: struct(module, func)} after
          collision resolution.
    """
    policy = ctx.attr.package_collisions

    def _complain(what, name, a, b):
        msg = "Package collision in {target}: {what} `{name}` is provided by both {a} and {b}.".format(
            target = str(ctx.label),
            what = what,
            name = name,
            a = a,
            b = b,
        )
        if policy == "error":
            fail(msg + "\nSet `package_collisions = \"warning\"` or \"ignore\" to downgrade.")
        elif policy == "warning":
            # buildifier: disable=print
            print(msg)

    # Pass 1: bucket claimants per top-level / per console-script name.
    # Collecting first and resolving second makes the namespace-benign
    # logic trivial (peek at the full list of claimants at once) and
    # avoids the subtle ordering issues a single-pass version had.
    tl_claimants = {}  # tl -> list of struct(site_packages, is_ns)
    cs_claimants = {}  # name -> list of struct(site_packages, module, func)
    for w in wheels:
        ns_set = {tl: True for tl in getattr(w, "namespace_top_levels", ())}
        for tl in w.top_levels:
            tl_claimants.setdefault(tl, []).append(struct(
                site_packages = w.site_packages_rfpath,
                is_ns = tl in ns_set,
            ))
        for entry in getattr(w, "console_scripts", ()):
            # Entry encoding from the repo rule: "name=module:func".
            if "=" not in entry:
                continue
            name, _, target = entry.partition("=")
            if ":" not in target:
                continue
            module, _, func = target.partition(":")
            name = name.strip()
            module = module.strip()
            func = func.strip()
            if not name or not module or not func:
                continue
            cs_claimants.setdefault(name, []).append(struct(
                site_packages = w.site_packages_rfpath,
                module = module,
                func = func,
            ))

    # Pass 2: resolve top-levels. Track which (site_packages, tl) pairs
    # we SKIPPED so pass 3 can decide which wheels are fully covered.
    top_level_to_site_pkgs = {}
    skipped_per_wheel = {}
    for tl, claimants in tl_claimants.items():
        # Deduplicate claimants by site_packages so a single wheel that
        # lists a name twice doesn't look like a collision against itself.
        distinct_sp = {c.site_packages: c for c in claimants}
        if len(distinct_sp) == 1:
            top_level_to_site_pkgs[tl] = claimants[0].site_packages
            continue

        # Multi-wheel claim: is it a benign namespace overlap?
        all_namespace = all([c.is_ns for c in claimants])
        if all_namespace:
            # Skip the symlink for every contributor. They'll still be
            # importable via addsitedir, which processes each wheel's
            # site-packages and lets Python's PEP 420 machinery walk
            # contributions across sys.path entries.
            for c in claimants:
                skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True
            continue

        # Real collision — first-seen wins; complain for each loser.
        first = claimants[0]
        top_level_to_site_pkgs[tl] = first.site_packages
        seen_losers = {}
        for c in claimants[1:]:
            if c.site_packages == first.site_packages or c.site_packages in seen_losers:
                continue
            _complain("top-level", tl, first.site_packages, c.site_packages)
            seen_losers[c.site_packages] = True
            skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True

    # Pass 2b: resolve console scripts. No namespace concept here.
    console_scripts_map = {}
    for name, claimants in cs_claimants.items():
        distinct_sp = {c.site_packages: c for c in claimants}
        if len(distinct_sp) == 1:
            c = claimants[0]
            console_scripts_map[name] = struct(module = c.module, func = c.func)
            continue
        first = claimants[0]
        console_scripts_map[name] = struct(module = first.module, func = first.func)
        seen_losers = {}
        for c in claimants[1:]:
            if c.site_packages == first.site_packages or c.site_packages in seen_losers:
                continue
            _complain("console script", name, first.site_packages, c.site_packages)
            seen_losers[c.site_packages] = True

    # Pass 3: which wheels are fully covered by direct symlinks?
    # A wheel is fully covered iff every top-level it claimed ended up
    # mapped to its own site-packages. Wheels that lost a collision or
    # contributed to a benign namespace are NOT fully covered — they
    # get added via .pth addsitedir so nothing is unreachable.
    fully_covered = {}
    for w in wheels:
        skipped = skipped_per_wheel.get(w.site_packages_rfpath, {})
        covered = True
        for tl in w.top_levels:
            if tl in skipped or top_level_to_site_pkgs.get(tl) != w.site_packages_rfpath:
                covered = False
                break
        if covered:
            fully_covered[w.site_packages_rfpath] = True

    return top_level_to_site_pkgs, fully_covered, console_scripts_map

def _py_binary_rule_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Resolve our `main=` to a label, which it isn't
    main = _py_semantics.determine_main(ctx)

    # Check for duplicate virtual dependency names. Those that map to the same resolution target would have been merged by the depset for us.
    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    # Collect wheels contributing metadata-rich PyWheelsInfo. Anything without
    # PyWheelsInfo (hand-written py_unpacked_wheel without `top_levels`, or
    # non-wheel py_library deps) falls through to the .pth path below.
    wheels_depset = _py_library.make_wheels_depset(ctx)
    wheels = wheels_depset.to_list()
    top_level_to_site_pkgs, fully_covered_site_pkgs, console_scripts_map = _resolve_wheel_collisions(ctx, wheels)

    # Assemble a minimal but real venv at build time:
    #
    #   <pkg>/.<safe_name>.venv/
    #     pyvenv.cfg                                         (ctx.actions.write)
    #     bin/python                                         (ctx.actions.symlink -> py_toolchain.python)
    #     lib/python<MAJ>.<MIN>/site-packages/
    #       <safe_name>.pth                                  (ctx.actions.write)
    #       <top_level>                                      (ctx.actions.symlink, one per wheel top-level)
    #
    # Because a real pyvenv.cfg sits next to bin/python, Python's startup
    # treats <venv>/lib/python<MAJ>.<MIN>/site-packages/ as a *site directory*.
    # Per-top-level symlinks give wheels a merged site-packages layout
    # equivalent to what pip/uv install. First-party import dirs (workspace
    # roots, py_library imports) + any wheels without PyWheelsInfo metadata
    # still go through the .pth fallback.
    #
    # '/' in the target name is flattened to '_' for the venv dir and .pth
    # filename so the layout is always single-segment regardless of the
    # target name. The executable launcher still uses ctx.attr.name verbatim.
    #
    # Components below the runfiles root, for the .pth's directory:
    #   1 workspace
    # + N package segments
    # + 1 venv segment
    # + 3 (lib, python<MAJ>.<MIN>, site-packages)
    safe_name = ctx.attr.name.replace("/", "_")
    py_ver = "python{}.{}".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    )
    package_depth = len(ctx.label.package.split("/")) if ctx.label.package else 0

    # Escape from the .pth file's / symlinks' directory
    # (<venv>/lib/pythonX.Y/site-packages/) up to the runfiles root.
    escape_count = 1 + package_depth + 1 + 3
    escape = "/".join([".."] * escape_count)

    # Escape from the venv root (= sys.prefix at runtime) up to the runfiles
    # root, used by the `import site; site.addsitedir(...)` fallback for
    # wheels without PyWheelsInfo metadata.
    #   <runfiles>/<ws>/<pkg...>/<venv>/ -> <runfiles>/
    # = 1 (ws) + package_depth + 1 (venv)
    venv_to_runfiles_escape = "/".join([".."] * (2 + package_depth))

    # Venv dir name intentionally uses `_venv` (underscore) suffix rather
    # than `.venv`. The `py_venv_link` macro declares a sibling target
    # `<name>.venv` whose tree artifact lands at `.<name>.venv/`, and
    # Bazel rejects two actions whose outputs are prefix-of-each-other.
    # See e2e/cases/venv-conflict-608.
    venv_name = ".{}_venv".format(safe_name)
    site_packages_rel = "{}/lib/{}/site-packages".format(venv_name, py_ver)

    # Per-top-level unresolved symlinks — one per wheel top-level. Each points
    # across the runfiles tree at the wheel repo's site-packages subdir.
    # Unresolved symlinks (declare_symlink + target_path) let us traverse
    # into another repo's tree-artifact output without needing per-top-level
    # file artifacts from the wheel rule.
    top_level_symlinks = []
    for tl, wheel_site_pkgs in top_level_to_site_pkgs.items():
        out = ctx.actions.declare_symlink("{}/{}".format(site_packages_rel, tl))
        ctx.actions.symlink(
            output = out,
            target_path = "{}/{}/{}".format(escape, wheel_site_pkgs, tl),
        )
        top_level_symlinks.append(out)

    # .pth for anything NOT handled by the top-level symlinks:
    #   * runfiles root itself (first line) — needed by rules_python runfiles helper
    #   * first-party import dirs (workspace roots, py_library imports)
    #   * wheel site-packages dirs whose owning wheel lacks PyWheelsInfo metadata
    #     (or whose coverage is partial due to collisions) — get the
    #     `site.addsitedir(...)` treatment so wheel-internal .pth files run
    pth_content_lines = [escape]
    for imp in imports_depset.to_list():
        if imp in fully_covered_site_pkgs:
            # Already handled by direct symlinks; skip to avoid duplicate
            # (and potentially out-of-order) sys.path entries.
            continue
        if imp.endswith("site-packages"):
            pth_content_lines.append(
                ("import os, sys, site; " +
                 "site.addsitedir(os.path.normpath(os.path.join(" +
                 "sys.prefix, \"{venv_escape}\", \"{imp}\")))").format(
                    venv_escape = venv_to_runfiles_escape,
                    imp = imp,
                ),
            )
        else:
            pth_content_lines.append("{}/{}".format(escape, imp))

    site_packages_pth_file = ctx.actions.declare_file(
        "{}/{}.pth".format(site_packages_rel, safe_name),
    )
    ctx.actions.write(
        output = site_packages_pth_file,
        content = "\n".join(pth_content_lines) + "\n",
    )

    # Minimal pyvenv.cfg — no `home`. Python follows the bin/python symlink
    # to the real interpreter and derives sys.base_prefix / stdlib from
    # there. We only need enough here for Python to recognise this as a
    # venv and set sys.prefix to <venv>.
    pyvenv_cfg = ctx.actions.declare_file("{}/pyvenv.cfg".format(venv_name))
    ctx.actions.write(
        output = pyvenv_cfg,
        content = "include-system-site-packages = false\nversion = {}.{}.{}\n".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
            py_toolchain.interpreter_version_info.micro,
        ),
    )

    # bin/python symlink. For the runfiles-interpreter case this is a
    # regular symlink to the interpreter File; for a system interpreter
    # (py_toolchain.python is a struct with .path pointing at an absolute
    # path) we produce an unresolved symlink to that absolute path.
    bin_python = ctx.actions.declare_file("{}/bin/python".format(venv_name))
    if py_toolchain.runfiles_interpreter:
        ctx.actions.symlink(
            output = bin_python,
            target_file = py_toolchain.python,
            is_executable = True,
        )
    else:
        ctx.actions.symlink(
            output = bin_python,
            target_path = py_toolchain.python.path,
        )

    # Console-script wrappers under <venv>/bin/<name>, one per wheel-declared
    # entry point (after collision resolution above). The launcher will
    # prepend <venv>/bin/ to $PATH so subprocess.run(["<name>", ...]) finds
    # these and dispatches to the venv's own python.
    console_script_files = []
    for name, target in console_scripts_map.items():
        script = ctx.actions.declare_file("{}/bin/{}".format(venv_name, name))
        ctx.actions.write(
            output = script,
            content = _CONSOLE_SCRIPT_TEMPLATE.format(
                name = name,
                module = target.module,
                func = target.func,
            ),
            is_executable = True,
        )
        console_script_files.append(script)

    default_env = {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = executable_launcher,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
            "{{INTERPRETER_FLAGS}}": " ".join(py_toolchain.flags + ctx.attr.interpreter_options),
            "{{ARG_VENV_PYTHON}}": to_rlocation_path(ctx, bin_python),
            "{{ENTRYPOINT}}": to_rlocation_path(ctx, main),
            "{{PYTHON_ENV}}": "\n".join(_dict_to_exports(default_env)).strip(),
        },
        is_executable = True,
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            py_toolchain.files,
            srcs_depset,
        ] + virtual_resolution.srcs + virtual_resolution.runfiles,
        extra_runfiles = [
            site_packages_pth_file,
            pyvenv_cfg,
            bin_python,
        ] + top_level_symlinks + console_script_files,
        extra_runfiles_depsets = [
            ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
        ],
    )

    instrumented_files_info = _py_library.make_instrumented_files_info(
        ctx,
        extra_source_attributes = ["main"],
    )

    return [
        DefaultInfo(
            files = depset([
                executable_launcher,
                main,
                site_packages_pth_file,
                pyvenv_cfg,
                bin_python,
            ] + top_level_symlinks + console_script_files),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
        PyInfo(
            imports = imports_depset,
            transitive_sources = srcs_depset,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        instrumented_files_info,
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
    "main": attr.label(
        allow_single_file = True,
        doc = """
Script to execute with the Python interpreter.

Must be a label pointing to a `.py` source file.
If such a label is provided, it will be honored.

If no label is provided AND there is only one `srcs` file, that `srcs` file will be used.

If there are more than one `srcs`, a file matching `{name}.py` is searched for.
This is for historical compatibility with the Bazel native `py_binary` and `rules_python`.
Relying on this behavior is STRONGLY discouraged, may produce warnings and may
be deprecated in the future.

""",
    ),
    "venv": attr.string(
        doc = """The name of the Python virtual environment within which deps should be resolved.

Part of the aspect_rules_py//uv system, has no effect in rules_python's pip.
""",
    ),
    "python_version": attr.string(
        doc = """Whether to build this target and its transitive deps for a specific python version.""",
    ),
    "interpreter_options": attr.string_list(
        doc = "Additional options to pass to the Python interpreter in addition to -B and -I passed by rules_py",
        default = [],
    ),
    "package_collisions": attr.string(
        doc = """What to do when two wheels in the transitive closure both claim the same top-level name in site-packages.

Wheels contribute top-level names via their `PyWheelsInfo` provider (populated
automatically by the `uv` wheel-install machinery from each wheel's
`*.dist-info/RECORD`). When two wheels declare the same top-level name
(e.g. both installing a `foo/` package), this attribute decides what happens:

* "error": Fail analysis with a message naming both wheels.
* "warning": Print a warning and use the first wheel seen; the second is skipped.
* "ignore": Use the first wheel silently; the second is skipped.

Wheels whose contents aren't visible to analysis (no `PyWheelsInfo`) can't
collide here — they fall through to `.pth`-based resolution where Python's
import order (first `sys.path` hit wins) decides.
""",
        default = "error",
        values = ["error", "warning", "ignore"],
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:run.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
})

_attrs.update(**_py_library.attrs)

_test_attrs = dict({
    "env_inherit": attr.string_list(
        doc = "Specifies additional environment variables to inherit from the external environment when the test is executed by bazel test.",
        default = [],
    ),
    # Magic attribute to make coverage --combined_report flag work.
    # There's no docs about this.
    # See https://github.com/bazelbuild/bazel/blob/fde4b67009d377a3543a3dc8481147307bd37d36/tools/test/collect_coverage.sh#L186-L194
    # NB: rules_python ALSO includes this attribute on the py_binary rule, but we think that's a mistake.
    # see https://github.com/aspect-build/rules_py/pull/520#pullrequestreview-2579076197
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
    ),
})

py_base = struct(
    implementation = _py_binary_rule_impl,
    attrs = _attrs,
    test_attrs = _test_attrs,
    toolchains = [
        PY_TOOLCHAIN,
    ],
    cfg = python_version_transition,
)

py_binary = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_binary macro](#py_binary) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    executable = True,
    cfg = py_base.cfg,
)

py_test = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_test macro](#py_test) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs | py_base.test_attrs,
    toolchains = py_base.toolchains,
    test = True,
    cfg = py_base.cfg,
)
