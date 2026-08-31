<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Stable public API for uv rules.

Graduated from `@aspect_rules_py//uv/unstable:defs.bzl` in rules_py v2.0.0.

<a id="gazelle_python_manifest"></a>

## gazelle_python_manifest

<pre>
load("@aspect_rules_py//uv:defs.bzl", "gazelle_python_manifest")

gazelle_python_manifest(<a href="#gazelle_python_manifest-name">name</a>, <a href="#gazelle_python_manifest-hub">hub</a>, <a href="#gazelle_python_manifest-venvs">venvs</a>, <a href="#gazelle_python_manifest-include_stub_packages">include_stub_packages</a>, <a href="#gazelle_python_manifest-platform_parent">platform_parent</a>)
</pre>

Generates a Gazelle Python manifest from uv-managed wheels.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="gazelle_python_manifest-name"></a>name |  Name of the generated manifest target.   |  none |
| <a id="gazelle_python_manifest-hub"></a>hub |  Name of the uv hub containing the wheels.   |  none |
| <a id="gazelle_python_manifest-venvs"></a>venvs |  Dependency groups whose wheels should be indexed.   |  `[]` |
| <a id="gazelle_python_manifest-include_stub_packages"></a>include_stub_packages |  Whether conventional stub distributions should be indexed for Gazelle's automatic stub dependency resolution.   |  `False` |
| <a id="gazelle_python_manifest-platform_parent"></a>platform_parent |  Parent platform for the synthetic platforms this macro uses to select each venv's wheels. Defaults to `Label("@platforms//host")`, resolved in rules_py's own repository — you do not need a `bazel_dep` on `platforms` to use the default. The host platform carries only OS and CPU constraints; point this at the platform the wheels should be resolved for when that is not enough:<br><br>- If the build sets a custom `--host_platform` (for example to carry   the constraints hermetic C++ toolchains require), pass that   platform here so sdist builds inside the hub can still resolve a   cc toolchain. - When cross-compiling, pass the target platform so wheel selection   follows it instead of snapping back to the host. Note this makes   `bazel run <name>.update` build any sdist fallbacks *for that   platform*, which requires an execution platform able to run the   build (e.g. remote execution) unless every indexed package   resolves to a wheel.   |  `None` |


<a id="py_console_script_binary"></a>

## py_console_script_binary

<pre>
load("@aspect_rules_py//uv:defs.bzl", "py_console_script_binary")

py_console_script_binary(<a href="#py_console_script_binary-name">name</a>, <a href="#py_console_script_binary-pkg">pkg</a>, <a href="#py_console_script_binary-script">script</a>, <a href="#py_console_script_binary-deps">deps</a>, <a href="#py_console_script_binary-dep_group">dep_group</a>, <a href="#py_console_script_binary-kwargs">**kwargs</a>)
</pre>

Build a binary for a console_script entrypoint of a package.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_console_script_binary-name"></a>name |  Name of the binary target.   |  none |
| <a id="py_console_script_binary-pkg"></a>pkg |  The package providing the console script (e.g. `@pypi//mkdocs`).   |  none |
| <a id="py_console_script_binary-script"></a>script |  Name of the console script as declared in the package's entry points. Defaults to `name`.   |  `None` |
| <a id="py_console_script_binary-deps"></a>deps |  Additional dependencies made available at runtime, beyond `pkg` and its own dependencies. Used for packages discovered dynamically via entry points, such as mkdocs or pytest plugins.   |  `[]` |
| <a id="py_console_script_binary-dep_group"></a>dep_group |  The dependency group within which to resolve dependencies, forwarded to the underlying `py_binary` targets.   |  `None` |
| <a id="py_console_script_binary-kwargs"></a>kwargs |  Attributes forwarded to the generated `py_binary` targets (e.g. `python_version`); `visibility` is applied only to the binary, since the search tool and genrule are private implementation details. Only universally-shared attributes (`tags`, `testonly`) are forwarded to the internal genrule.   |  none |


<a id="py_entrypoint_binary"></a>

## py_entrypoint_binary

<pre>
load("@aspect_rules_py//uv:defs.bzl", "py_entrypoint_binary")

py_entrypoint_binary(<a href="#py_entrypoint_binary-name">name</a>, <a href="#py_entrypoint_binary-entrypoint">entrypoint</a>, <a href="#py_entrypoint_binary-pkg">pkg</a>, <a href="#py_entrypoint_binary-visibility">visibility</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_entrypoint_binary-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="py_entrypoint_binary-entrypoint"></a>entrypoint |  <p align="center"> - </p>   |  none |
| <a id="py_entrypoint_binary-pkg"></a>pkg |  <p align="center"> - </p>   |  none |
| <a id="py_entrypoint_binary-visibility"></a>visibility |  <p align="center"> - </p>   |  `["//visibility:public"]` |


