# `py_unittest_test` drives a suite with stdlib `unittest`. The declared
# source files are baked into a private per-test entrypoint rendered from
# unittest_main.py, which imports each file exactly once under a unique module
# name.

load("//py/private:py_library.bzl", "py_library")
load(
    "//py/private/py_venv:defs.bzl",
    "py_binary_with_venv",
    "py_venv_exec_test",
)

def _unittest_main_impl(ctx):
    # Bake the source files (runfiles-relative). The driver loads each file
    # directly, so it never recurses directories (avoiding double-run of nested
    # roots and same-basename collisions from discover()). External-repo sources
    # (../reponame/...) resolve from the runfiles root at load time, so keep them.
    test_files = [src.short_path for src in ctx.files.srcs]
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.out,
        # Key on the bare assignment line (not a trailing comment) so the
        # template's explanatory comments can change without silently defeating
        # the substitution.
        substitutions = {
            "test_files: List[str] = []": "test_files: List[str] = " + repr(sorted(test_files)),
        },
    )

_unittest_main = rule(
    implementation = _unittest_main_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "out": attr.output(mandatory = True),
        "_template": attr.label(
            allow_single_file = True,
            default = Label("//py/private:unittest_main.py"),
        ),
    },
)

def py_unittest_test(
        name,
        srcs = [],
        deps = [],
        resolutions = None,
        **kwargs):
    """A `py_test` that runs under the stdlib `unittest` framework.

    Loads each `srcs` file and collects its `unittest.TestCase`s. Integrates
    with Bazel coverage, sharding, JUnit XML, and `--test_filter`. No pytest
    dependency required.

    Every file in `srcs` is a test module. Put importable support code in
    `deps`; to select tests by name pattern, use Bazel's `glob()` in the `srcs`
    list.

    Runtime `args` are parsed by the driver: `-v`/`-q`, `-f`/`--failfast`,
    `-b`/`--buffer`, and `-k PATTERN` (native unittest `-k`: repeatable,
    ORed, `*` is fnmatch). Unknown args are rejected rather than ignored.

    Args:
        name: Name of the rule.
        srcs: Python test source files; each is loaded as a test module.
        deps: Dependencies. `coverage` is required only for coverage; JUnit XML
            is emitted by a built-in writer, so no third-party runner is needed.
        resolutions: virtual-dep resolutions, `"string" -> label`.
        **kwargs: forwarded to the underlying test rule and sibling py_venv.
    """
    if "main" in kwargs:
        fail("py_unittest_test provides its own entrypoint; `main` is not supported. Use py_test for a custom main.")

    kwargs["testonly"] = True

    if resolutions:
        resolutions = resolutions.to_label_keyed_dict()

    tags = kwargs.get("tags", [])

    # Render the entrypoint for this target with the srcs baked in.
    main_src = "__unittest__%s__.py" % name
    _unittest_main(
        name = name + "_unittest_main",
        srcs = srcs,
        out = main_src,
        testonly = True,
        tags = tags,
    )
    main_lib = name + "_unittest_main_lib"
    py_library(
        name = main_lib,
        srcs = [main_src],
        imports = ["."],
        testonly = True,
        tags = tags,
    )

    py_binary_with_venv(
        py_venv_exec_test,
        name = name,
        srcs = srcs,
        deps = list(deps) + [":" + main_lib],
        main = ":" + main_src,
        resolutions = resolutions,
        **kwargs
    )
