<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Create a zip file containing a full Python application.

Follows [PEP-441 (PEX)](https://peps.python.org/pep-0441/)

## Ensuring a compatible interpreter is used

The resulting zip file does *not* contain a Python interpreter.
Users are expected to execute the PEX with a compatible interpreter on the runtime system.

Use the `python_interpreter_constraints` to provide an error if a wrong interpreter tries to execute the PEX, for example:

```starlark
py_pex_binary(
    python_interpreter_constraints = [
        "CPython=={major}.{minor}.{patch}",
    ]
)
```


<a id="py_pex_binary"></a>

## py_pex_binary

<pre>
py_pex_binary(<a href="#py_pex_binary-name">name</a>, <a href="#py_pex_binary-binary">binary</a>, <a href="#py_pex_binary-inherit_path">inherit_path</a>, <a href="#py_pex_binary-inject_env">inject_env</a>, <a href="#py_pex_binary-python_interpreter_constraints">python_interpreter_constraints</a>,
              <a href="#py_pex_binary-python_shebang">python_shebang</a>)
</pre>

Build a pex executable from a py_binary

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_pex_binary-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_pex_binary-binary"></a>binary |  A py_binary target   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_pex_binary-inherit_path"></a>inherit_path |  Whether to inherit the <code>sys.path</code> (aka PYTHONPATH) of the environment that the binary runs in.<br><br>Use <code>false</code> to not inherit <code>sys.path</code>; use <code>fallback</code> to inherit <code>sys.path</code> after packaged dependencies; and use <code>prefer</code> to inherit <code>sys.path</code> before packaged dependencies.   | String | optional | <code>""</code> |
| <a id="py_pex_binary-inject_env"></a>inject_env |  Environment variables to set when running the pex binary.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_pex_binary-python_interpreter_constraints"></a>python_interpreter_constraints |  Python interpreter versions this PEX binary is compatible with. A list of semver strings.  The placeholder strings <code>{major}</code>, <code>{minor}</code>, <code>{patch}</code> can be used for gathering version  information from the hermetic python toolchain.   | List of strings | optional | <code>["CPython=={major}.{minor}.*"]</code> |
| <a id="py_pex_binary-python_shebang"></a>python_shebang |  -   | String | optional | <code>"#!/usr/bin/env python3"</code> |


