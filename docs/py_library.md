<!-- Generated with Stardoc: http://skydoc.bazel.build -->

A re-implementation of [py_library](https://bazel.build/reference/be/python#py_library).

Supports "virtual" dependencies with a `virtual_deps` attribute, which lists packages which are required
without binding them to a particular version of that package.


<a id="py_library"></a>

## py_library

<pre>
py_library(<a href="#py_library-name">name</a>, <a href="#py_library-data">data</a>, <a href="#py_library-deps">deps</a>, <a href="#py_library-imports">imports</a>, <a href="#py_library-resolutions">resolutions</a>, <a href="#py_library-srcs">srcs</a>, <a href="#py_library-virtual_deps">virtual_deps</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_library-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_library-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_library-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_library-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_library-resolutions"></a>resolutions |  Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.         See [virtual dependencies](/docs/virtual_deps.md).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_library-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_library-virtual_deps"></a>virtual_deps |  -   | List of strings | optional | <code>[]</code> |


<a id="py_library_utils.implementation"></a>

## py_library_utils.implementation

<pre>
py_library_utils.implementation(<a href="#py_library_utils.implementation-ctx">ctx</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.implementation-ctx"></a>ctx |  <p align="center"> - </p>   |  none |


<a id="py_library_utils.make_imports_depset"></a>

## py_library_utils.make_imports_depset

<pre>
py_library_utils.make_imports_depset(<a href="#py_library_utils.make_imports_depset-ctx">ctx</a>, <a href="#py_library_utils.make_imports_depset-imports">imports</a>, <a href="#py_library_utils.make_imports_depset-extra_imports_depsets">extra_imports_depsets</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.make_imports_depset-ctx"></a>ctx |  <p align="center"> - </p>   |  none |
| <a id="py_library_utils.make_imports_depset-imports"></a>imports |  <p align="center"> - </p>   |  <code>[]</code> |
| <a id="py_library_utils.make_imports_depset-extra_imports_depsets"></a>extra_imports_depsets |  <p align="center"> - </p>   |  <code>[]</code> |


<a id="py_library_utils.make_instrumented_files_info"></a>

## py_library_utils.make_instrumented_files_info

<pre>
py_library_utils.make_instrumented_files_info(<a href="#py_library_utils.make_instrumented_files_info-ctx">ctx</a>, <a href="#py_library_utils.make_instrumented_files_info-extra_source_attributes">extra_source_attributes</a>,
                                              <a href="#py_library_utils.make_instrumented_files_info-extra_dependency_attributes">extra_dependency_attributes</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.make_instrumented_files_info-ctx"></a>ctx |  <p align="center"> - </p>   |  none |
| <a id="py_library_utils.make_instrumented_files_info-extra_source_attributes"></a>extra_source_attributes |  <p align="center"> - </p>   |  <code>[]</code> |
| <a id="py_library_utils.make_instrumented_files_info-extra_dependency_attributes"></a>extra_dependency_attributes |  <p align="center"> - </p>   |  <code>[]</code> |


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


<a id="py_library_utils.make_srcs_depset"></a>

## py_library_utils.make_srcs_depset

<pre>
py_library_utils.make_srcs_depset(<a href="#py_library_utils.make_srcs_depset-ctx">ctx</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.make_srcs_depset-ctx"></a>ctx |  <p align="center"> - </p>   |  none |


<a id="py_library_utils.resolve_virtuals"></a>

## py_library_utils.resolve_virtuals

<pre>
py_library_utils.resolve_virtuals(<a href="#py_library_utils.resolve_virtuals-ctx">ctx</a>, <a href="#py_library_utils.resolve_virtuals-ignore_missing">ignore_missing</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library_utils.resolve_virtuals-ctx"></a>ctx |  <p align="center"> - </p>   |  none |
| <a id="py_library_utils.resolve_virtuals-ignore_missing"></a>ignore_missing |  <p align="center"> - </p>   |  <code>False</code> |


