<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API re-exports

<a id="py_binary_rule"></a>

## py_binary_rule

<pre>
py_binary_rule(<a href="#py_binary_rule-name">name</a>, <a href="#py_binary_rule-data">data</a>, <a href="#py_binary_rule-deps">deps</a>, <a href="#py_binary_rule-env">env</a>, <a href="#py_binary_rule-imports">imports</a>, <a href="#py_binary_rule-main">main</a>, <a href="#py_binary_rule-resolutions">resolutions</a>, <a href="#py_binary_rule-srcs">srcs</a>)
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
| <a id="py_binary_rule-main"></a>main |  Script to execute with the Python interpreter.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_binary_rule-resolutions"></a>resolutions |  FIXME   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_binary_rule-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_library_rule"></a>

## py_library_rule

<pre>
py_library_rule(<a href="#py_library_rule-name">name</a>, <a href="#py_library_rule-data">data</a>, <a href="#py_library_rule-deps">deps</a>, <a href="#py_library_rule-imports">imports</a>, <a href="#py_library_rule-resolutions">resolutions</a>, <a href="#py_library_rule-srcs">srcs</a>, <a href="#py_library_rule-virtual_deps">virtual_deps</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_library_rule-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_library_rule-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_library_rule-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_library_rule-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_library_rule-resolutions"></a>resolutions |  FIXME   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_library_rule-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_library_rule-virtual_deps"></a>virtual_deps |  -   | List of strings | optional | <code>[]</code> |


<a id="py_test_rule"></a>

## py_test_rule

<pre>
py_test_rule(<a href="#py_test_rule-name">name</a>, <a href="#py_test_rule-data">data</a>, <a href="#py_test_rule-deps">deps</a>, <a href="#py_test_rule-env">env</a>, <a href="#py_test_rule-imports">imports</a>, <a href="#py_test_rule-main">main</a>, <a href="#py_test_rule-resolutions">resolutions</a>, <a href="#py_test_rule-srcs">srcs</a>)
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
| <a id="py_test_rule-resolutions"></a>resolutions |  FIXME   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_test_rule-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_venv"></a>

## py_venv

<pre>
py_venv(<a href="#py_venv-name">name</a>, <a href="#py_venv-data">data</a>, <a href="#py_venv-deps">deps</a>, <a href="#py_venv-imports">imports</a>, <a href="#py_venv-resolutions">resolutions</a>, <a href="#py_venv-srcs">srcs</a>, <a href="#py_venv-strip_pth_workspace_root">strip_pth_workspace_root</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_venv-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_venv-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv-resolutions"></a>resolutions |  FIXME   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_venv-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv-strip_pth_workspace_root"></a>strip_pth_workspace_root |  -   | Boolean | optional | <code>True</code> |


<a id="py_wheel"></a>

## py_wheel

<pre>
py_wheel(<a href="#py_wheel-name">name</a>, <a href="#py_wheel-src">src</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_wheel-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_wheel-src"></a>src |  The Wheel file, as defined by https://packaging.python.org/en/latest/specifications/binary-distribution-format/#binary-distribution-format   | <a href="https://bazel.build/concepts/labels">Label</a> | optional | <code>None</code> |


<a id="dep"></a>

## dep

<pre>
dep(<a href="#dep-name">name</a>, <a href="#dep-virtual">virtual</a>, <a href="#dep-constraint">constraint</a>, <a href="#dep-prefix">prefix</a>, <a href="#dep-default">default</a>, <a href="#dep-from_label">from_label</a>)
</pre>

Creates a Python dependency reference from the libraries name.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="dep-name"></a>name |  Name of the dependency to include   |  none |
| <a id="dep-virtual"></a>virtual |  If true, the dependency is considered "virtual", and the terminal py_* rule must provide a concrete dependency label   |  <code>False</code> |
| <a id="dep-constraint"></a>constraint |  If the dependency is considered virtual, provide an optional constraint over the version range that the virtual dependency can be satisfied by.   |  <code>None</code> |
| <a id="dep-prefix"></a>prefix |  The dependency label prefix, defaults to "pypi"   |  <code>"pypi"</code> |
| <a id="dep-default"></a>default |  Default target that will provide this dependency if none is provided at the terminal rule.   |  <code>None</code> |
| <a id="dep-from_label"></a>from_label |  When given in conjunction with name, maps the name to a concrete dependency label, can be used to override the default resolved via this helper.   |  <code>None</code> |


<a id="make_dep_helper"></a>

## make_dep_helper

<pre>
make_dep_helper(<a href="#make_dep_helper-prefix">prefix</a>)
</pre>

Returns a function that assists in making dependency references when using virtual dependencies.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="make_dep_helper-prefix"></a>prefix |  The prefix to attach to all dependency labels, representing the external repository that the external dependency is defined in.   |  <code>"pypi"</code> |


<a id="mypy_aspect"></a>

## mypy_aspect

<pre>
mypy_aspect(<a href="#mypy_aspect-binary">binary</a>, <a href="#mypy_aspect-configs">configs</a>)
</pre>

A factory function to create a linter aspect.

Attrs:
    binary: a mypy executable
    configs: mypy config file(s) such as mypy.ini or pyproject.toml, see
        https://mypy.readthedocs.io/en/stable/config_file.html#config-file

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="mypy_aspect-binary"></a>binary |  <p align="center"> - </p>   |  none |
| <a id="mypy_aspect-configs"></a>configs |  <p align="center"> - </p>   |  none |


<a id="py_binary"></a>

## py_binary

<pre>
py_binary(<a href="#py_binary-name">name</a>, <a href="#py_binary-srcs">srcs</a>, <a href="#py_binary-main">main</a>, <a href="#py_binary-imports">imports</a>, <a href="#py_binary-resolutions">resolutions</a>, <a href="#py_binary-kwargs">kwargs</a>)
</pre>

Wrapper macro for [`py_binary_rule`](#py_binary_rule), setting a default for imports.

It also creates a virtualenv to constrain the interpreter and packages used at runtime,
you can `bazel run [name].venv` to produce this, then use it in the editor.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_binary-name"></a>name |  name of the rule   |  none |
| <a id="py_binary-srcs"></a>srcs |  python source files   |  <code>[]</code> |
| <a id="py_binary-main"></a>main |  the entry point. If absent, then the first entry in srcs is used.   |  <code>None</code> |
| <a id="py_binary-imports"></a>imports |  List of import paths to add for this binary.   |  <code>["."]</code> |
| <a id="py_binary-resolutions"></a>resolutions |  FIXME   |  <code>{}</code> |
| <a id="py_binary-kwargs"></a>kwargs |  additional named parameters to the py_binary_rule   |  none |


<a id="py_library"></a>

## py_library

<pre>
py_library(<a href="#py_library-name">name</a>, <a href="#py_library-imports">imports</a>, <a href="#py_library-deps">deps</a>, <a href="#py_library-kwargs">kwargs</a>)
</pre>

Wrapper macro for the [py_library_rule](./py_library_rule), supporting virtual deps.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library-name"></a>name |  name of resulting py_library_rule   |  none |
| <a id="py_library-imports"></a>imports |  List of import paths to add for this library.   |  <code>["."]</code> |
| <a id="py_library-deps"></a>deps |  Dependencies for this Python library.   |  <code>[]</code> |
| <a id="py_library-kwargs"></a>kwargs |  additional named parameters to py_library_rule   |  none |


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
py_test(<a href="#py_test-name">name</a>, <a href="#py_test-main">main</a>, <a href="#py_test-srcs">srcs</a>, <a href="#py_test-imports">imports</a>, <a href="#py_test-kwargs">kwargs</a>)
</pre>

Identical to py_binary, but produces a target that can be used with `bazel test`.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_test-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="py_test-main"></a>main |  <p align="center"> - </p>   |  <code>None</code> |
| <a id="py_test-srcs"></a>srcs |  <p align="center"> - </p>   |  <code>[]</code> |
| <a id="py_test-imports"></a>imports |  <p align="center"> - </p>   |  <code>["."]</code> |
| <a id="py_test-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


<a id="resolutions"></a>

## resolutions

<pre>
resolutions(<a href="#resolutions-base">base</a>, <a href="#resolutions-overrides">overrides</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="resolutions-base"></a>base |  <p align="center"> - </p>   |  none |
| <a id="resolutions-overrides"></a>overrides |  <p align="center"> - </p>   |  <code>{}</code> |


