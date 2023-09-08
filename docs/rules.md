<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API re-exports

<a id="py_venv"></a>

## py_venv

<pre>
py_venv(<a href="#py_venv-name">name</a>, <a href="#py_venv-data">data</a>, <a href="#py_venv-deps">deps</a>, <a href="#py_venv-imports">imports</a>, <a href="#py_venv-srcs">srcs</a>, <a href="#py_venv-strip_pth_workspace_root">strip_pth_workspace_root</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_venv-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_venv-data"></a>data |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv-deps"></a>deps |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv-imports"></a>imports |  -   | List of strings | optional | <code>[]</code> |
| <a id="py_venv-srcs"></a>srcs |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
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
| <a id="py_wheel-src"></a>src |  -   | <a href="https://bazel.build/concepts/labels">Label</a> | optional | <code>None</code> |


<a id="py_binary"></a>

## py_binary

<pre>
py_binary(<a href="#py_binary-name">name</a>, <a href="#py_binary-srcs">srcs</a>, <a href="#py_binary-main">main</a>, <a href="#py_binary-imports">imports</a>, <a href="#py_binary-kwargs">kwargs</a>)
</pre>

Wrapper macro for the py_binary rule, setting a default for imports.

It also creates a virtualenv to constrain the interpreter and packages used at runtime,
you can `bazel run [name].venv` to produce this, then use it in the editor.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_binary-name"></a>name |  name of the rule   |  none |
| <a id="py_binary-srcs"></a>srcs |  python source files   |  <code>[]</code> |
| <a id="py_binary-main"></a>main |  the entry point. If absent, then the first entry in srcs is used.   |  <code>None</code> |
| <a id="py_binary-imports"></a>imports |  List of import paths to add for this binary.   |  <code>["."]</code> |
| <a id="py_binary-kwargs"></a>kwargs |  see [py_binary attributes](./py_binary)   |  none |


<a id="py_library"></a>

## py_library

<pre>
py_library(<a href="#py_library-name">name</a>, <a href="#py_library-kwargs">kwargs</a>)
</pre>

Wrapper macro for the py_library rule, setting a default for imports

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library-name"></a>name |  name of the rule   |  none |
| <a id="py_library-kwargs"></a>kwargs |  see [py_library attributes](./py_library)   |  none |


<a id="py_pytest_main"></a>

## py_pytest_main

<pre>
py_pytest_main(<a href="#py_pytest_main-name">name</a>, <a href="#py_pytest_main-py_library">py_library</a>, <a href="#py_pytest_main-deps">deps</a>, <a href="#py_pytest_main-kwargs">kwargs</a>)
</pre>

py_pytest_main wraps the template rendering target and the final py_library.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_pytest_main-name"></a>name |  The name of the runable target that updates the test entry file.   |  none |
| <a id="py_pytest_main-py_library"></a>py_library |  Use this attribute to override the default py_library rule.   |  <code>&lt;function py_library&gt;</code> |
| <a id="py_pytest_main-deps"></a>deps |  A list containing the pytest library target, e.g., @pypi_pytest//:pkg.   |  <code>[]</code> |
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


