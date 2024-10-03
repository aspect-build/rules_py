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


<a id="py_test_rule"></a>

## py_test_rule

<pre>
py_test_rule(<a href="#py_test_rule-name">name</a>, <a href="#py_test_rule-data">data</a>, <a href="#py_test_rule-deps">deps</a>, <a href="#py_test_rule-env">env</a>, <a href="#py_test_rule-imports">imports</a>, <a href="#py_test_rule-main">main</a>, <a href="#py_test_rule-package_collisions">package_collisions</a>, <a href="#py_test_rule-python_version">python_version</a>, <a href="#py_test_rule-resolutions">resolutions</a>,
             <a href="#py_test_rule-srcs">srcs</a>)
</pre>

Run a Python program under Bazel. Most users should use the [py_test macro](#py_test) instead of loading this directly.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_test_rule-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_test_rule-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_test_rule-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_test_rule-env"></a>env |  Environment variables to set when running the binary.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_test_rule-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_test_rule-main"></a>main |  Script to execute with the Python interpreter.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_test_rule-package_collisions"></a>package_collisions |  The action that should be taken when a symlink collision is encountered when creating the venv. A collision can occour when multiple packages providing the same file are installed into the venv. The possible values are:<br><br>* "error": When conflicting symlinks are found, an error is reported and venv creation halts. * "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues. * "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.   | String | optional | <code>"error"</code> |
| <a id="py_test_rule-python_version"></a>python_version |  Whether to build this target and its transitive deps for a specific python version.   | String | optional | <code>""</code> |
| <a id="py_test_rule-resolutions"></a>resolutions |  FIXME   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_test_rule-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_pytest_main"></a>

## py_pytest_main

<pre>
py_pytest_main(<a href="#py_pytest_main-name">name</a>, <a href="#py_pytest_main-py_library">py_library</a>, <a href="#py_pytest_main-deps">deps</a>, <a href="#py_pytest_main-data">data</a>, <a href="#py_pytest_main-testonly">testonly</a>, <a href="#py_pytest_main-kwargs">kwargs</a>)
</pre>

py_pytest_main wraps the template rendering target and the final py_library.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_pytest_main-name"></a>name |  The name of the runable target that updates the test entry file.   |  none |
| <a id="py_pytest_main-py_library"></a>py_library |  Use this attribute to override the default py_library rule.   |  <code>&lt;unknown object com.google.devtools.build.skydoc.fakebuildapi.FakeStarlarkRuleFunctionsApi$RuleDefinitionIdentifier&gt;</code> |
| <a id="py_pytest_main-deps"></a>deps |  A list containing the pytest library target, e.g., @pypi_pytest//:pkg.   |  <code>[]</code> |
| <a id="py_pytest_main-data"></a>data |  A list of data dependencies to pass to the py_library target.   |  <code>[]</code> |
| <a id="py_pytest_main-testonly"></a>testonly |  A boolean indicating if the py_library target is testonly.   |  <code>True</code> |
| <a id="py_pytest_main-kwargs"></a>kwargs |  The extra arguments passed to the template rendering target.   |  none |


<a id="py_test"></a>

## py_test

<pre>
py_test(<a href="#py_test-name">name</a>, <a href="#py_test-main">main</a>, <a href="#py_test-srcs">srcs</a>, <a href="#py_test-kwargs">kwargs</a>)
</pre>

Identical to [py_binary](./py_binary.md), but produces a target that can be used with `bazel test`.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_test-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="py_test-main"></a>main |  <p align="center"> - </p>   |  <code>None</code> |
| <a id="py_test-srcs"></a>srcs |  <p align="center"> - </p>   |  <code>[]</code> |
| <a id="py_test-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


