<!-- Generated with Stardoc: http://skydoc.bazel.build -->

py_image_layer macro for creating multiple layers from a py_binary

&gt; [!WARNING]
&gt; This macro is EXPERIMENTAL and is not subject to our SemVer guarantees.

A py_binary that uses `torch` and `numpy` can use the following layer groups:

```
load("@rules_oci//oci:defs.bzl", "oci_image")
load("@aspect_rules_py//py:defs.bzl", "py_image_layer", "py_binary")

py_binary(
    name = "my_app_bin",
    deps = [
        "@pip_deps//numpy",
        "@pip_deps//torch"
    ]
)

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


<a id="py_image_layer"></a>

## py_image_layer

<pre>
py_image_layer(<a href="#py_image_layer-name">name</a>, <a href="#py_image_layer-binary">binary</a>, <a href="#py_image_layer-root">root</a>, <a href="#py_image_layer-layer_groups">layer_groups</a>, <a href="#py_image_layer-compress">compress</a>, <a href="#py_image_layer-tar_args">tar_args</a>, <a href="#py_image_layer-compute_unused_inputs">compute_unused_inputs</a>,
               <a href="#py_image_layer-platform">platform</a>, <a href="#py_image_layer-kwargs">kwargs</a>)
</pre>

Produce a separate tar output for each layer of a python app

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
    "packages": "\.runfiles/.*/site-packages",, # contains third-party deps
    "interpreter": "\.runfiles/python.*-.*/", # contains the python interpreter
}
```


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_image_layer-name"></a>name |  base name for targets   |  none |
| <a id="py_image_layer-binary"></a>binary |  a py_binary target   |  none |
| <a id="py_image_layer-root"></a>root |  Path to where the layers should be rooted. If not specified, the layers will be rooted at the workspace root.   |  <code>"/"</code> |
| <a id="py_image_layer-layer_groups"></a>layer_groups |  Additional layer groups to create. They are used to group files into layers based on their path. In the form of: <pre><code>{"&lt;name&gt;": "regex_to_match_against_file_paths"}</code></pre>   |  <code>{}</code> |
| <a id="py_image_layer-compress"></a>compress |  Compression algorithm to use. Default is gzip. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule-compress   |  <code>"gzip"</code> |
| <a id="py_image_layer-tar_args"></a>tar_args |  Additional arguments to pass to the tar rule. Default is <code>[]</code>. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule-args   |  <code>[]</code> |
| <a id="py_image_layer-compute_unused_inputs"></a>compute_unused_inputs |  Whether to compute unused inputs. Default is 1. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule-compute_unused_inputs   |  <code>1</code> |
| <a id="py_image_layer-platform"></a>platform |  The platform to use for the transition. Default is None. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/transitions.md#platform_transition_binary-target_platform   |  <code>None</code> |
| <a id="py_image_layer-kwargs"></a>kwargs |  attribute that apply to all targets expanded by the macro   |  none |

**RETURNS**

A list of labels for each layer.


