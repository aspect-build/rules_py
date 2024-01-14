"""Some vendored helper code, copied from Bazel:
https://github.com/bazelbuild/bazel/blob/37983b2f89cca7cc8b0bd596f4558fa36c8fbff2/src/main/starlark/builtins_bzl/common/python/py_executable.bzl

There's not a way for us to reference that at runtime (via @bazel_tools, say) and even if there was
we don't want to have to detect the version of Bazel that the user is running to know whether code
we want to re-use will be present.
"""

def csv(values):
    """Convert a list of strings to comma separated value string."""
    return ", ".join(sorted(values))

def _path_endswith(path, endswith):
    # Use slash to anchor each path to prevent e.g.
    # "ab/c.py".endswith("b/c.py") from incorrectly matching.
    return ("/" + path).endswith("/" + endswith)

def _determine_main(ctx):
    """Determine the main entry point .py source file.

    Args:
        ctx: The rule ctx.

    Returns:
        Artifact; the main file. If one can't be found, an error is raised.
    """
    if ctx.attr.main:
        # Deviation from rules_python: allow a leading colon, e.g. `main = ":my_target"`
        proposed_main = ctx.attr.main.removeprefix(":")
        if not proposed_main.endswith(".py"):
            fail("main must end in '.py'")
    else:
        if ctx.attr.target_name.endswith(".py"):
            fail("name must not end in '.py'")
        proposed_main = ctx.attr.target_name + ".py"

    main_files = [src for src in ctx.files.srcs if _path_endswith(src.short_path, proposed_main)]

    ###
    # Deviation from logic in rules_python: rules_py is a bit more permissive.
    # Allow a srcs of length one to determine the main, if the target name didn't
    if not main_files and len(ctx.files.srcs) == 1:
        main_files = ctx.files.srcs

    ### End deviations

    if not main_files:
        if ctx.attr.main:
            fail("could not find '{}' as specified by 'main' attribute".format(proposed_main))
        else:
            fail(("corresponding default '{}' does not appear in srcs. Add " +
                  "it or override default file name with a 'main' attribute").format(
                proposed_main,
            ))

    elif len(main_files) > 1:
        if ctx.attr.main:
            fail(("file name '{}' specified by 'main' attributes matches multiple files. " +
                  "Matches: {}").format(
                proposed_main,
                csv([f.short_path for f in main_files]),
            ))
        else:
            fail(("default main file '{}' matches multiple files in srcs. Perhaps specify " +
                  "an explicit file with 'main' attribute? Matches were: {}").format(
                proposed_main,
                csv([f.short_path for f in main_files]),
            ))
    return main_files[0]

# Adapts the function above, which we copied from rules_python, to be a standalone rule so we can
# use it from a macro.
# (We want our underlying py_binary rule to be simple: 'main' is a mandatory label)
def _determine_main_impl(ctx):
    return DefaultInfo(files = depset([_determine_main(ctx)]))

determine_main = rule(
    doc = """rules_python compatibility shim: find a main file with the given name among the srcs.

    From rules_python:
    https://github.com/bazelbuild/rules_python/blob/4fe0db3cdcc063d5bdeab756e948640f3f16ae33/python/private/common/py_executable.bzl#L73
    # TODO(b/203567235): In the Java impl, any file is allowed. While marked
    # label, it is more treated as a string, and doesn't have to refer to
    # anything that exists because it gets treated as suffix-search string
    # over `srcs`.

    We think these are lame semantics, however we want rules_py to be a drop-in replacement for rules_python.
    """,
    implementation = _determine_main_impl,
    attrs = {
        "target_name": attr.string(mandatory = True, doc = "The name of the py_binary or py_test we are finding a main for"),
        "main": attr.string("Hint the user supplied as the main"),
        "srcs": attr.label_list(allow_files = True),
    },
)
