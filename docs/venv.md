<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Implementation for the py_binary and py_test rules.

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


<a id="py_venv"></a>

## py_venv

<pre>
py_venv(<a href="#py_venv-kwargs">kwargs</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


<a id="py_venv_binary"></a>

## py_venv_binary

<pre>
py_venv_binary(<a href="#py_venv_binary-kwargs">kwargs</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv_binary-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


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


<a id="py_venv_test"></a>

## py_venv_test

<pre>
py_venv_test(<a href="#py_venv_test-kwargs">kwargs</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv_test-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


