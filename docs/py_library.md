<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Implementation for the py_library rule

<a id="py_library"></a>

## py_library

<pre>
py_library(<a href="#py_library-name">name</a>, <a href="#py_library-data">data</a>, <a href="#py_library-deps">deps</a>, <a href="#py_library-imports">imports</a>, <a href="#py_library-srcs">srcs</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_library-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_library-data"></a>data |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | [] |
| <a id="py_library-deps"></a>deps |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | [] |
| <a id="py_library-imports"></a>imports |  -   | List of strings | optional | [] |
| <a id="py_library-srcs"></a>srcs |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | [] |


<a id="py_library_utils.make_srcs_depset"></a>

## py_library_utils.make_srcs_depset

<pre>
py_library_utils.make_srcs_depset(<a href="#py_library_utils.make_srcs_depset-ctx">ctx</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.make_srcs_depset-ctx"></a>ctx |  <p align="center"> - </p>   |  none |


<a id="py_library_utils.make_imports_depset"></a>

## py_library_utils.make_imports_depset

<pre>
py_library_utils.make_imports_depset(<a href="#py_library_utils.make_imports_depset-ctx">ctx</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.make_imports_depset-ctx"></a>ctx |  <p align="center"> - </p>   |  none |


<a id="py_library_utils.make_merged_runfiles"></a>

## py_library_utils.make_merged_runfiles

<pre>
py_library_utils.make_merged_runfiles(<a href="#py_library_utils.make_merged_runfiles-ctx">ctx</a>, <a href="#py_library_utils.make_merged_runfiles-extra_depsets">extra_depsets</a>, <a href="#py_library_utils.make_merged_runfiles-extra_runfiles">extra_runfiles</a>, <a href="#py_library_utils.make_merged_runfiles-extra_runfiles_depsets">extra_runfiles_depsets</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.make_merged_runfiles-ctx"></a>ctx |  <p align="center"> - </p>   |  none |
| <a id="py_library_utils.make_merged_runfiles-extra_depsets"></a>extra_depsets |  <p align="center"> - </p>   |  <code>[]</code> |
| <a id="py_library_utils.make_merged_runfiles-extra_runfiles"></a>extra_runfiles |  <p align="center"> - </p>   |  <code>[]</code> |
| <a id="py_library_utils.make_merged_runfiles-extra_runfiles_depsets"></a>extra_runfiles_depsets |  <p align="center"> - </p>   |  <code>[]</code> |


<a id="py_library_utils.implementation"></a>

## py_library_utils.implementation

<pre>
py_library_utils.implementation(<a href="#py_library_utils.implementation-ctx">ctx</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.implementation-ctx"></a>ctx |  <p align="center"> - </p>   |  none |


