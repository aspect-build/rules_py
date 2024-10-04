<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Re-implementations of [py_binary](https://bazel.build/reference/be/python#py_binary)
and [py_test](https://bazel.build/reference/be/python#py_test)

## Choosing the Python version

The `python_version` attribute must refer to a python toolchain version
which has been registered in the WORKSPACE or MODULE.bazel file.

When using WORKSPACE, this may look like this:

```starlark
load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")

python_register_toolchains(
    name = "python_toolchain_3_8",
    python_version = "3.8.12",
    # setting set_python_version_constraint makes it so that only matches py_* rule  
    # which has this exact version set in the `python_version` attribute.
    set_python_version_constraint = True,
)

# It's important to register the default toolchain last it will match any py_* target. 
python_register_toolchains(
    name = "python_toolchain",
    python_version = "3.9",
)
```

Configuring for MODULE.bazel may look like this:

```starlark
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.8.12", is_default = False)
python.toolchain(python_version = "3.9", is_default = True)
```


<a id="py_image_layer"></a>

## py_image_layer

<pre>
py_image_layer(<a href="#py_image_layer-name">name</a>, <a href="#py_image_layer-py_binary">py_binary</a>, <a href="#py_image_layer-root">root</a>, <a href="#py_image_layer-layer_groups">layer_groups</a>, <a href="#py_image_layer-compress">compress</a>, <a href="#py_image_layer-tar_args">tar_args</a>, <a href="#py_image_layer-kwargs">kwargs</a>)
</pre>

Produce a separate tar output for each layer of a python app

&gt; Note: This macro is EXPERIMENTAL and is not subject to our SemVer guarantees.

&gt; Requires `awk` to be installed on the host machine/rbe runner.

For better performance, it is recommended to split the output of a py_binary into multiple layers.
This can be done by grouping files into layers based on their path by using the `layer_groups` attribute.

The matching order for layer groups is as follows:
    1. `layer_groups` are checked first.
    2. If no match is found for `layer_groups`, the `default layer groups` are checked.
    3. Any remaining files are placed into the default layer.

The default layer groups are:
```
{
    "packages": "\.runfiles/pip_deps.*", # contains third-party deps
    "interpreter": "\.runfiles/python.*-.*/", # contains the python interpreter
}
```

A py_binary that uses `torch` and `numpy` can use the following layer groups:

```
oci_image(
    tars = py_image_layer(
        name = "my_app",
        py_binary = ":my_app_bin",
        layer_groups = {
            "torch": "pip_deps_torch.*",
            "numpy": "pip_deps_numpy.*",
        }
    )
)
```



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_image_layer-name"></a>name |  base name for targets   |  none |
| <a id="py_image_layer-py_binary"></a>py_binary |  a py_binary target   |  none |
| <a id="py_image_layer-root"></a>root |  Path to where the layers should be rooted. If not specified, the layers will be rooted at the workspace root.   |  <code>None</code> |
| <a id="py_image_layer-layer_groups"></a>layer_groups |  Additional layer groups to create. They are used to group files into layers based on their path. In the form of: <pre><code>{"&lt;name&gt;": "regex_to_match_against_file_paths"}</code></pre>   |  <code>{}</code> |
| <a id="py_image_layer-compress"></a>compress |  Compression algorithm to use. Default is gzip. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule   |  <code>"gzip"</code> |
| <a id="py_image_layer-tar_args"></a>tar_args |  Additional arguments to pass to the tar rule. Default is <code>["--options", "gzip:!timestamp"]</code>. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule   |  <code>["--options", "gzip:!timestamp"]</code> |
| <a id="py_image_layer-kwargs"></a>kwargs |  attribute that apply to all targets expanded by the macro   |  none |

**RETURNS**

A list of labels for each layer.


