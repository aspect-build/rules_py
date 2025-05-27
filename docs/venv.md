<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Implementation for the py_binary and py_test rules.

<a id="py_venv"></a>

## py_venv

<pre>
py_venv(<a href="#py_venv-name">name</a>, <a href="#py_venv-data">data</a>, <a href="#py_venv-deps">deps</a>, <a href="#py_venv-env">env</a>, <a href="#py_venv-imports">imports</a>, <a href="#py_venv-interpreter_options">interpreter_options</a>, <a href="#py_venv-package_collisions">package_collisions</a>, <a href="#py_venv-python_version">python_version</a>,
        <a href="#py_venv-resolutions">resolutions</a>, <a href="#py_venv-srcs">srcs</a>)
</pre>

Build a Python virtual environment and execute its interpreter.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_venv-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_venv-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv-env"></a>env |  Environment variables to set when running the binary.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_venv-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv-interpreter_options"></a>interpreter_options |  Additional options to pass to the Python interpreter.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv-package_collisions"></a>package_collisions |  The action that should be taken when a symlink collision is encountered when creating the venv. A collision can occur when multiple packages providing the same file are installed into the venv. The possible values are:<br><br>* "error": When conflicting symlinks are found, an error is reported and venv creation halts. * "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues. * "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.   | String | optional | <code>"error"</code> |
| <a id="py_venv-python_version"></a>python_version |  Whether to build this target and its transitive deps for a specific python version.   | String | optional | <code>""</code> |
| <a id="py_venv-resolutions"></a>resolutions |  Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.         See [virtual dependencies](/docs/virtual_deps.md).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_venv-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_venv_binary"></a>

## py_venv_binary

<pre>
py_venv_binary(<a href="#py_venv_binary-name">name</a>, <a href="#py_venv_binary-data">data</a>, <a href="#py_venv_binary-deps">deps</a>, <a href="#py_venv_binary-env">env</a>, <a href="#py_venv_binary-imports">imports</a>, <a href="#py_venv_binary-interpreter_options">interpreter_options</a>, <a href="#py_venv_binary-main">main</a>, <a href="#py_venv_binary-package_collisions">package_collisions</a>,
               <a href="#py_venv_binary-python_version">python_version</a>, <a href="#py_venv_binary-resolutions">resolutions</a>, <a href="#py_venv_binary-srcs">srcs</a>, <a href="#py_venv_binary-venv">venv</a>)
</pre>

Run a Python program under Bazel using a virtualenv.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_venv_binary-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_venv_binary-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv_binary-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv_binary-env"></a>env |  Environment variables to set when running the binary.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_venv_binary-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv_binary-interpreter_options"></a>interpreter_options |  Additional options to pass to the Python interpreter.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv_binary-main"></a>main |  Script to execute with the Python interpreter.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_venv_binary-package_collisions"></a>package_collisions |  The action that should be taken when a symlink collision is encountered when creating the venv. A collision can occur when multiple packages providing the same file are installed into the venv. The possible values are:<br><br>* "error": When conflicting symlinks are found, an error is reported and venv creation halts. * "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues. * "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.   | String | optional | <code>"error"</code> |
| <a id="py_venv_binary-python_version"></a>python_version |  Whether to build this target and its transitive deps for a specific python version.   | String | optional | <code>""</code> |
| <a id="py_venv_binary-resolutions"></a>resolutions |  Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.         See [virtual dependencies](/docs/virtual_deps.md).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_venv_binary-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv_binary-venv"></a>venv |  A virtualenv; if provided all 3rdparty deps are assumed to come via the venv.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional | <code>None</code> |


<a id="py_venv_test"></a>

## py_venv_test

<pre>
py_venv_test(<a href="#py_venv_test-name">name</a>, <a href="#py_venv_test-data">data</a>, <a href="#py_venv_test-deps">deps</a>, <a href="#py_venv_test-env">env</a>, <a href="#py_venv_test-env_inherit">env_inherit</a>, <a href="#py_venv_test-imports">imports</a>, <a href="#py_venv_test-interpreter_options">interpreter_options</a>, <a href="#py_venv_test-main">main</a>,
             <a href="#py_venv_test-package_collisions">package_collisions</a>, <a href="#py_venv_test-python_version">python_version</a>, <a href="#py_venv_test-resolutions">resolutions</a>, <a href="#py_venv_test-srcs">srcs</a>, <a href="#py_venv_test-venv">venv</a>)
</pre>

Run a Python program under Bazel using a virtualenv.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_venv_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_venv_test-data"></a>data |  Runtime dependencies of the program.<br><br>        The transitive closure of the <code>data</code> dependencies will be available in the <code>.runfiles</code>         folder for this binary/test. The program may optionally use the Runfiles lookup library to         locate the data files, see https://pypi.org/project/bazel-runfiles/.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv_test-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv_test-env"></a>env |  Environment variables to set when running the binary.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_venv_test-env_inherit"></a>env_inherit |  Specifies additional environment variables to inherit from the external environment when the test is executed by bazel test.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv_test-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv_test-interpreter_options"></a>interpreter_options |  Additional options to pass to the Python interpreter.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv_test-main"></a>main |  Script to execute with the Python interpreter.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_venv_test-package_collisions"></a>package_collisions |  The action that should be taken when a symlink collision is encountered when creating the venv. A collision can occur when multiple packages providing the same file are installed into the venv. The possible values are:<br><br>* "error": When conflicting symlinks are found, an error is reported and venv creation halts. * "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues. * "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.   | String | optional | <code>"error"</code> |
| <a id="py_venv_test-python_version"></a>python_version |  Whether to build this target and its transitive deps for a specific python version.   | String | optional | <code>""</code> |
| <a id="py_venv_test-resolutions"></a>resolutions |  Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.         See [virtual dependencies](/docs/virtual_deps.md).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_venv_test-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv_test-venv"></a>venv |  A virtualenv; if provided all 3rdparty deps are assumed to come via the venv.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional | <code>None</code> |


<a id="VirtualenvInfo"></a>

## VirtualenvInfo

<pre>
VirtualenvInfo(<a href="#VirtualenvInfo-home">home</a>)
</pre>


    Provider used to distinguish venvs from py rules.
    

**FIELDS**


| Name  | Description |
| :------------- | :------------- |
| <a id="VirtualenvInfo-home"></a>home |  Path of the virtualenv    |


<a id="py_venv_link"></a>

## py_venv_link

<pre>
py_venv_link(<a href="#py_venv_link-venv_name">venv_name</a>, <a href="#py_venv_link-kwargs">kwargs</a>)
</pre>

Build a Python virtual environment and produce a script to link it into the build directory.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv_link-venv_name"></a>venv_name |  <p align="center"> - </p>   |  <code>None</code> |
| <a id="py_venv_link-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


