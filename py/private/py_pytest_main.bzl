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
    """Compute the unique directories containing test sources and write them to a file."""
    dirs = {}
    for src in ctx.files.srcs:
        p = src.short_path

        # Skip external-repo sources (../reponame/...) — only the test's
        # own workspace sources should be discovery roots.
        if p.startswith("../"):
            continue
        if "/" in p:
            dirs[p.rsplit("/", 1)[0]] = True
        else:
            dirs[""] = True
    out = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.write(out, "\n".join(sorted(dirs.keys())))
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

pytest_paths = rule(
    doc = "Computes the set of directories containing test sources for pytest collection.",
    implementation = _pytest_paths_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files whose parent directories become pytest search roots.",
        ),
    },
)

def _py_pytest_main_impl(ctx):
    substitutions = {
        "user_args: List[str] = []": "user_args: List[str] = " + repr([f for f in ctx.attr.args]),
        "_ = 0  # no-op": "os.chdir('{}')".format(ctx.attr.chdir) if ctx.attr.chdir else "_ = 0  # no-op",
    }

    ctx.actions.expand_template(
        template = ctx.file.template,
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
        "template": attr.label(
            doc = """INTERNAL USE ONLY.
            A python script to be called as the pytest main.
            Default values in the template are replaced before executing the script.
            This is not considered a Public API. Replacements may change without warning.
            """,
            allow_single_file = True,
            default = Label("//py/private:pytest.py.tmpl"),
        ),
    },
)

def py_pytest_main(name, py_library = default_py_library, deps = [], data = [], testonly = True, **kwargs):
    """py_pytest_main wraps the template rendering target and the final py_library.

    Args:
        name: The name of the runable target that updates the test entry file.
        py_library: Use this attribute to override the default py_library rule.
        deps: A list containing the pytest library target, e.g., @pypi_pytest//:pkg.
        data: A list of data dependencies to pass to the py_library target.
        testonly: A boolean indicating if the py_library target is testonly.
        **kwargs: The extra arguments passed to the template rendering target.
    """

    if not kwargs.get("args") and not kwargs.get("chdir"):
        # buildifier: disable=print
        print("WARNING: py_pytest_main(name = \"%s\") has no custom args or chdir. " % name +
              "Use py_test(pytest_main = True) instead, which avoids generating a " +
              "per-test entry script. py_pytest_main without custom parameters " +
              "will be removed in a future release.")

    # Use __test__<name>__.py so pytest won't discover the generated main
    # as a test module (see #723). The double-underscore wrapping signals
    # "internal/dunder" to pytest's default collection rules.
    # Skip wrapping if the name is already dunder-wrapped (e.g. "__test__").
    if name.startswith("__") and name.endswith("__"):
        test_main = name + ".py"
    else:
        test_main = "__test__" + name + "__.py"
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
