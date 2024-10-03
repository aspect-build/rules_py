<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Create a Python virtualenv directory structure.

Note that [py_binary](./py_binary.md#py_binary) and [py_test](./py_test.md#py_test) macros automatically provide `[name].venv` targets.
Using `py_venv` directly is only required for cases where those defaults do not apply.

&gt; [!NOTE]
&gt; As an implementation detail, this currently uses &lt;https://github.com/prefix-dev/rip&gt; which is a very fast Rust-based tool.


<a id="py_venv_rule"></a>

## py_venv_rule

<pre>
py_venv_rule(<a href="#py_venv_rule-name">name</a>, <a href="#py_venv_rule-deps">deps</a>, <a href="#py_venv_rule-imports">imports</a>, <a href="#py_venv_rule-location">location</a>, <a href="#py_venv_rule-package_collisions">package_collisions</a>, <a href="#py_venv_rule-resolutions">resolutions</a>, <a href="#py_venv_rule-venv_name">venv_name</a>)
</pre>

Create a Python virtual environment with the dependencies listed.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_venv_rule-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_venv_rule-deps"></a>deps |  Targets that produce Python code, commonly <code>py_library</code> rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_venv_rule-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional | <code>[]</code> |
| <a id="py_venv_rule-location"></a>location |  Path from the workspace root for where to root the virtial environment   | String | optional | <code>""</code> |
| <a id="py_venv_rule-package_collisions"></a>package_collisions |  The action that should be taken when a symlink collision is encountered when creating the venv. A collision can occour when multiple packages providing the same file are installed into the venv. The possible values are:<br><br>* "error": When conflicting symlinks are found, an error is reported and venv creation halts. * "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues. * "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.   | String | optional | <code>"error"</code> |
| <a id="py_venv_rule-resolutions"></a>resolutions |  FIXME   | <a href="https://bazel.build/rules/lib/dict">Dictionary: Label -> String</a> | optional | <code>{}</code> |
| <a id="py_venv_rule-venv_name"></a>venv_name |  Outer folder name for the generated virtual environment   | String | optional | <code>""</code> |


<a id="py_venv"></a>

## py_venv

<pre>
py_venv(<a href="#py_venv-name">name</a>, <a href="#py_venv-kwargs">kwargs</a>)
</pre>

Wrapper macro for [`py_venv_rule`](#py_venv_rule).

Chooses a suitable default location for the resulting directory.

By default, VSCode (and likely other tools) expect to find virtualenv's in the root of the project opened in the editor.
They also provide a nice name to see "which one is open" when discovered this way.
See https://github.com/aspect-build/rules_py/issues/395

Use py_venv_rule directly to have more control over the location.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="py_venv-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


