<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API re-exports

<a id="#py_wheel"></a>

## py_wheel

<pre>
py_wheel(<a href="#py_wheel-name">name</a>, <a href="#py_wheel-src">src</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_wheel-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/docs/build-ref.html#name">Name</a> | required |  |
| <a id="py_wheel-src"></a>src |  -   | <a href="https://bazel.build/docs/build-ref.html#labels">Label</a> | optional | None |


<a id="#py_binary"></a>

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
| <a id="py_binary-imports"></a>imports |  <p align="center"> - </p>   |  <code>["."]</code> |
| <a id="py_binary-kwargs"></a>kwargs |  see [py_binary attributes](./py_binary)   |  none |


<a id="#py_library"></a>

## py_library

<pre>
py_library(<a href="#py_library-name">name</a>, <a href="#py_library-imports">imports</a>, <a href="#py_library-kwargs">kwargs</a>)
</pre>

Wrapper macro for the py_library rule, setting a default for imports

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library-name"></a>name |  name of the rule   |  none |
| <a id="py_library-imports"></a>imports |  <p align="center"> - </p>   |  <code>["."]</code> |
| <a id="py_library-kwargs"></a>kwargs |  see [py_library attributes](./py_library)   |  none |


<a id="#py_test"></a>

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


