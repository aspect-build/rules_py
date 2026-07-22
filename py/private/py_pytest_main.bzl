# Copyright 2022 Aspect Build Systems, Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""py_test entrypoint generation.
"""

load(":py_library.bzl", default_py_library = "py_library")

def _pytest_paths_impl(ctx):
    """Write the test source files pytest should collect (runfiles-relative).

    Every src is a test module by contract, so pytest collects exactly these
    paths: a target scopes to its own srcs instead of a directory (a
    workspace-root source would otherwise yield an empty root and make pytest
    recurse the whole runfiles tree, collecting unrelated files supplied as
    data). Support code belongs in `deps`, and conftest.py in `data`."""
    files = {}
    for src in ctx.files.srcs:
        # short_path is runfiles-relative, so external-repo sources
        # (../reponame/...) resolve from the runfiles root at collection time
        # too — keep them instead of dropping a target's only sources.
        files[src.short_path] = True
    out = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.write(out, "\n".join(sorted(files.keys())))
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

pytest_paths = rule(
    doc = "Writes the test source files for pytest to collect (one path per line).",
    implementation = _pytest_paths_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Test source files passed to pytest as explicit collection targets.",
        ),
    },
)

def wrapped_main_filename(name):
    """The generated pytest-main filename for `name`, dunder-wrapping only the
    final path segment so pytest won't collect it (#723) while preserving any
    directory prefix from a `/`-containing target name (#483)."""
    if "/" in name:
        prefix, base = name.rsplit("/", 1)
        prefix += "/"
    else:
        prefix, base = "", name

    # Skip re-wrapping a segment that is already dunder-wrapped (e.g. "__test__").
    if base.startswith("__") and base.endswith("__"):
        return prefix + base + ".py"
    return prefix + "__test__" + base + "__.py"

def _py_pytest_main_impl(ctx):
    substitutions = {
        "user_args: List[str] = []": "user_args: List[str] = " + repr([f for f in ctx.attr.args]),
        # repr() renders a valid Python string literal, so paths containing
        # quotes/backslashes (e.g. "pkg/it's-data") don't break the chdir call.
        "_ = 0  # no-op": "os.chdir({})".format(repr(ctx.attr.chdir)) if ctx.attr.chdir else "_ = 0  # no-op",
    }

    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.out,
        substitutions = dict(substitutions, **ctx.var),
        is_executable = False,
    )

_py_pytest_main = rule(
    implementation = _py_pytest_main_impl,
    attrs = {
        "args": attr.string_list(
            doc = "Additional arguments to pass to pytest.",
        ),
        "chdir": attr.string(
            doc = "A path to a directory to chdir when the test starts.",
            mandatory = False,
        ),
        "out": attr.output(
            doc = "The output file.",
            mandatory = True,
        ),
        "_template": attr.label(
            doc = "The pytest main script; substitution markers are replaced before use.",
            allow_single_file = True,
            default = Label("//py/private:pytest_main.py"),
        ),
    },
)

def py_pytest_main(name, py_library = default_py_library, deps = [], data = [], testonly = True, **kwargs):
    """py_pytest_main wraps the template rendering target and the final py_library.

    Low-level escape hatch: prefer [py_pytest_test](#py_pytest_test) for pytest
    suites. Use this only for hand-written or wrapped entrypoints (e.g. exposing
    an importable `main()` for custom setup/teardown around pytest).

    Args:
        name: The name of the runable target that updates the test entry file.
        py_library: Use this attribute to override the default py_library rule.
        deps: A list containing the pytest library target, e.g., @pypi_pytest//:pkg.
        data: A list of data dependencies to pass to the py_library target.
        testonly: A boolean indicating if the py_library target is testonly.
        **kwargs: The extra arguments passed to the template rendering target.
    """

    # Dunder-wrap the generated main so pytest won't collect it as a test
    # module (#723), preserving any directory prefix for slash names (#483).
    test_main = wrapped_main_filename(name)
    tags = kwargs.pop("tags", [])
    visibility = kwargs.pop("visibility", [])

    _py_pytest_main(
        name = "%s_template" % name,
        out = test_main,
        tags = tags,
        visibility = visibility,
        **kwargs
    )

    py_library(
        name = name,
        testonly = testonly,
        srcs = [test_main],
        tags = tags,
        visibility = visibility,
        deps = deps + [Label("//py/private/pytest_shard")],
        data = data,
    )
