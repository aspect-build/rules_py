<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API re-exports

<a id="py_binary_rule"></a>

## py_binary_rule

<pre>
py_binary_rule(<a href="#py_binary_rule-name">name</a>, <a href="#py_binary_rule-data">data</a>, <a href="#py_binary_rule-deps">deps</a>, <a href="#py_binary_rule-env">env</a>, <a href="#py_binary_rule-imports">imports</a>, <a href="#py_binary_rule-main">main</a>, <a href="#py_binary_rule-python_version">python_version</a>, <a href="#py_binary_rule-resolutions">resolutions</a>, <a href="#py_binary_rule-srcs">srcs</a>)
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
| <a id="py_binary_rule-python_version"></a>python_version |  Whether to build this target and its transitive deps for a specific python version.<br><br>Note that setting this attribute alone will not be enough as the python toolchain for the desired version also needs to be registered in the WORKSPACE or MODULE.bazel file.<br><br>When using WORKSPACE, this may look like this,<br><br><pre><code> load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")<br><br>python_register_toolchains(     name = "python_toolchain_3_8",     python_version = "3.8.12",     # setting set_python_version_constraint makes it so that only matches py_* rule       # which has this exact version set in the <code>python_version</code> attribute.     set_python_version_constraint = True, )<br><br># It's important to register the default toolchain last it will match any py_* target.  python_register_toolchains(     name = "python_toolchain",     python_version = "3.9", ) </code></pre><br><br>Configuring for MODULE.bazel may look like this:<br><br><pre><code> python = use_extension("@rules_python//python/extensions:python.bzl", "python") python.toolchain(python_version = "3.8.12", is_default = False) python.toolchain(python_version = "3.9", is_default = True) </code></pre>   | String | optional | <code>""</code> |
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


<a id="py_pex_binary"></a>

## py_pex_binary

<pre>
py_pex_binary(<a href="#py_pex_binary-name">name</a>, <a href="#py_pex_binary-binary">binary</a>, <a href="#py_pex_binary-inject_env">inject_env</a>, <a href="#py_pex_binary-python_shebang">python_shebang</a>)
</pre>

Build a pex executable from a py_binary

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_pex_binary-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_pex_binary-binary"></a>binary |  -   | <a href="https://bazel.build/concepts/labels">Label</a> | optional | <code>None</code> |
| <a id="py_pex_binary-inject_env"></a>inject_env |  Environment variables to set when running the pex binary.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_pex_binary-python_shebang"></a>python_shebang |  -   | String | optional | <code>"#!/usr/bin/env python3"</code> |


<a id="py_test_rule"></a>

## py_test_rule

<pre>
py_test_rule(<a href="#py_test_rule-name">name</a>, <a href="#py_test_rule-data">data</a>, <a href="#py_test_rule-deps">deps</a>, <a href="#py_test_rule-env">env</a>, <a href="#py_test_rule-imports">imports</a>, <a href="#py_test_rule-main">main</a>, <a href="#py_test_rule-python_version">python_version</a>, <a href="#py_test_rule-resolutions">resolutions</a>, <a href="#py_test_rule-srcs">srcs</a>)
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
| <a id="py_test_rule-python_version"></a>python_version |  Whether to build this target and its transitive deps for a specific python version.<br><br>Note that setting this attribute alone will not be enough as the python toolchain for the desired version also needs to be registered in the WORKSPACE or MODULE.bazel file.<br><br>When using WORKSPACE, this may look like this,<br><br><pre><code> load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")<br><br>python_register_toolchains(     name = "python_toolchain_3_8",     python_version = "3.8.12",     # setting set_python_version_constraint makes it so that only matches py_* rule       # which has this exact version set in the <code>python_version</code> attribute.     set_python_version_constraint = True, )<br><br># It's important to register the default toolchain last it will match any py_* target.  python_register_toolchains(     name = "python_toolchain",     python_version = "3.9", ) </code></pre><br><br>Configuring for MODULE.bazel may look like this:<br><br><pre><code> python = use_extension("@rules_python//python/extensions:python.bzl", "python") python.toolchain(python_version = "3.8.12", is_default = False) python.toolchain(python_version = "3.9", is_default = True) </code></pre>   | String | optional | <code>""</code> |
| <a id="py_test_rule-resolutions"></a>resolutions |  FIXME   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_test_rule-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_unpacked_wheel_rule"></a>

## py_unpacked_wheel_rule

<pre>
py_unpacked_wheel_rule(<a href="#py_unpacked_wheel_rule-name">name</a>, <a href="#py_unpacked_wheel_rule-py_package_name">py_package_name</a>, <a href="#py_unpacked_wheel_rule-src">src</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_unpacked_wheel_rule-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_unpacked_wheel_rule-py_package_name"></a>py_package_name |  -   | String | required |  |
| <a id="py_unpacked_wheel_rule-src"></a>src |  The Wheel file, as defined by https://packaging.python.org/en/latest/specifications/binary-distribution-format/#binary-distribution-format   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="py_binary"></a>

## py_binary

<pre>
py_binary(<a href="#py_binary-name">name</a>, <a href="#py_binary-srcs">srcs</a>, <a href="#py_binary-main">main</a>, <a href="#py_binary-imports">imports</a>, <a href="#py_binary-kwargs">kwargs</a>)
</pre>

Wrapper macro for [`py_binary_rule`](#py_binary_rule), setting a default for imports.

It also creates a virtualenv to constrain the interpreter and packages used at runtime,
you can `bazel run [name].venv` to produce this, then use it in the editor.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_binary-name"></a>name |  Name of the rule.   |  none |
| <a id="py_binary-srcs"></a>srcs |  Python source files.   |  <code>[]</code> |
| <a id="py_binary-main"></a>main |  Entry point. Like rules_python, this is treated as a suffix of a file that should appear among the srcs. If absent, then "[name].py" is tried. As a final fallback, if the srcs has a single file, that is used as the main.   |  <code>None</code> |
| <a id="py_binary-imports"></a>imports |  List of import paths to add for this binary.   |  <code>["."]</code> |
| <a id="py_binary-kwargs"></a>kwargs |  additional named parameters to the py_binary_rule.   |  none |


<a id="py_library"></a>

## py_library

<pre>
py_library(<a href="#py_library-name">name</a>, <a href="#py_library-imports">imports</a>, <a href="#py_library-kwargs">kwargs</a>)
</pre>

Wrapper macro for the [py_library_rule](./py_library_rule), supporting virtual deps.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_library-name"></a>name |  Name for this rule.   |  none |
| <a id="py_library-imports"></a>imports |  List of import paths to add for this library.   |  <code>["."]</code> |
| <a id="py_library-kwargs"></a>kwargs |  Additional named parameters to py_library_rule.   |  none |


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


<a id="py_unpacked_wheel"></a>

## py_unpacked_wheel

<pre>
py_unpacked_wheel(<a href="#py_unpacked_wheel-name">name</a>, <a href="#py_unpacked_wheel-kwargs">kwargs</a>)
</pre>

Wrapper macro for the [py_unpacked_wheel_rule](#py_unpacked_wheel_rule), setting a defaults.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_unpacked_wheel-name"></a>name |  Name of this rule.   |  none |
| <a id="py_unpacked_wheel-kwargs"></a>kwargs |  Additional named parameters to py_unpacked_wheel_rule.   |  none |


<a id="py_venv"></a>

## py_venv

<pre>
py_venv(<a href="#py_venv-name">name</a>, <a href="#py_venv-kwargs">kwargs</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="py_venv-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


<a id="resolutions.from_requirements"></a>

## resolutions.from_requirements

<pre>
resolutions.from_requirements(<a href="#resolutions.from_requirements-base">base</a>, <a href="#resolutions.from_requirements-requirement_fn">requirement_fn</a>)
</pre>

Returns data representing the resolution for a given set of dependencies

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="resolutions.from_requirements-base"></a>base |  Base set of requirements to turn into resolutions.   |  none |
| <a id="resolutions.from_requirements-requirement_fn"></a>requirement_fn |  Optional function to transform the Python package name into a requirement label.   |  <code>&lt;function lambda&gt;</code> |

**RETURNS**

A resolution struct for use with virtual deps.


<a id="resolutions.empty"></a>

## resolutions.empty

<pre>
resolutions.empty()
</pre>





