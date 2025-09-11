<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Re-implementations of [py_binary](https://bazel.build/reference/be/python#py_binary)
and [py_test](https://bazel.build/reference/be/python#py_test)

## Choosing the Python version

The `python_version` attribute must refer to a python toolchain version
which has been registered in the WORKSPACE or MODULE.bazel file.

When using WORKSPACE, this may look like this:

```starlark
load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")

python_register_toolchains(
    name = "python_toolchain_3_8",
    python_version = "3.8.12",
    # setting set_python_version_constraint makes it so that only matches py_* rule
    # which has this exact version set in the `python_version` attribute.
    set_python_version_constraint = True,
)

# It's important to register the default toolchain last it will match any py_* target.
python_register_toolchains(
    name = "python_toolchain",
    python_version = "3.9",
)
```

Configuring for MODULE.bazel may look like this:

```starlark
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.8.12", is_default = False)
python.toolchain(python_version = "3.9", is_default = True)
```


<a id="py_binary_rule"></a>

## py_binary_rule

<pre>
py_binary_rule(<a href="#py_binary_rule-name">name</a>, <a href="#py_binary_rule-data">data</a>, <a href="#py_binary_rule-deps">deps</a>, <a href="#py_binary_rule-env">env</a>, <a href="#py_binary_rule-imports">imports</a>, <a href="#py_binary_rule-interpreter_options">interpreter_options</a>, <a href="#py_binary_rule-main">main</a>, <a href="#py_binary_rule-package_collisions">package_collisions</a>,
               <a href="#py_binary_rule-python_version">python_version</a>, <a href="#py_binary_rule-resolutions">resolutions</a>, <a href="#py_binary_rule-srcs">srcs</a>)
</pre>

Run a Python program under Bazel. Most users should use the [py_binary macro](#py_binary) instead of loading this directly.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_binary_rule-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_binary_rule-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_binary_rule-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_binary_rule-env"></a>env |  Environment variables to set when running the binary.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_binary_rule-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_binary_rule-interpreter_options"></a>interpreter_options |  Additional options to pass to the Python interpreter in addition to -B and -I passed by rules_py   | List of strings | optional | <code>[]</code> |
| <a id="py_binary_rule-main"></a>main |  Script to execute with the Python interpreter. Like rules_python, this is treated as a suffix of a file that should appear among the srcs. If absent, then <code>[name].py</code> is tried. As a final fallback, if the srcs has a single file, that is used as the main.   | String | optional | <code>""</code> |
| <a id="py_binary_rule-package_collisions"></a>package_collisions |  The action that should be taken when a symlink collision is encountered when creating the venv. A collision can occur when multiple packages providing the same file are installed into the venv. The possible values are:<br><br>* "error": When conflicting symlinks are found, an error is reported and venv creation halts. * "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues. * "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.   | String | optional | <code>"error"</code> |
| <a id="py_binary_rule-python_version"></a>python_version |  Whether to build this target and its transitive deps for a specific python version.   | String | optional | <code>""</code> |
| <a id="py_binary_rule-resolutions"></a>resolutions |  Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.         See [virtual dependencies](/docs/virtual_deps.md).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_binary_rule-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_binary"></a>

## py_binary

<pre>
py_binary(<a href="#py_binary-name">name</a>, <a href="#py_binary-srcs">srcs</a>, <a href="#py_binary-main">main</a>, <a href="#py_binary-kwargs">kwargs</a>)
</pre>

Wrapper macro for [`py_binary_rule`](#py_binary_rule).

Creates a [py_venv](./venv.md) target to constrain the interpreter and packages used at runtime.
Users can `bazel run [name].venv` to create this virtualenv, then use it in the editor or other tools.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_binary-name"></a>name |  Name of the rule.   |  none |
| <a id="py_binary-srcs"></a>srcs |  Python source files.   |  <code>[]</code> |
| <a id="py_binary-main"></a>main |  Entry point. Like rules_python, this is treated as a suffix of a file that should appear among the srcs. If absent, then <code>[name].py</code> is tried. As a final fallback, if the srcs has a single file, that is used as the main.   |  <code>None</code> |
| <a id="py_binary-kwargs"></a>kwargs |  additional named parameters to <code>py_binary_rule</code>.   |  none |


