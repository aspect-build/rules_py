<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Re-implementations of [py_binary](https://bazel.build/reference/be/python#py_binary)
and [py_test](https://bazel.build/reference/be/python#py_test)

## Choosing the Python version

The `python_version` attribute must refer to a python toolchain version
which has been registered in the `MODULE.bazel` file, e.g.:

```starlark
interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
interpreters.toolchain(python_version = "3.10")
interpreters.toolchain(python_version = "3.12")
use_repo(interpreters, "python_interpreters")

register_toolchains("@python_interpreters//:all")
```

<a id="current_py_toolchain"></a>

## current_py_toolchain

<pre>
load("@aspect_rules_py//py:defs.bzl", "current_py_toolchain")

current_py_toolchain(<a href="#current_py_toolchain-name">name</a>)
</pre>

Exposes the resolved Python 3 toolchain as Make variables.

After toolchain resolution, this rule provides `$(PYTHON3)` and
`$(PYTHON3_ROOTPATH)` for Make variable expansion in rules like
`genrule` and `bazel_env`.

An instance is automatically available at
`@python_interpreters//:current_py_toolchain` when using the
`python_interpreters` module extension.

Example usage with `genrule`:

```starlark
genrule(
    name = "run_python",
    outs = ["output.txt"],
    cmd = "$(PYTHON3) -c 'print(42)' > $@",
    toolchains = ["@python_interpreters//:current_py_toolchain"],
)
```

Example usage with `bazel_env`:

```starlark
bazel_env(
    name = "bazel_env",
    toolchains = {
        "python": "@python_interpreters//:current_py_toolchain",
    },
    tools = {
        "python": "$(PYTHON3)",
    },
)
```

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="current_py_toolchain-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |


<a id="py_layer_compressor"></a>

## py_layer_compressor

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_layer_compressor")

py_layer_compressor(<a href="#py_layer_compressor-name">name</a>, <a href="#py_layer_compressor-args">args</a>, <a href="#py_layer_compressor-extension">extension</a>, <a href="#py_layer_compressor-tool">tool</a>)
</pre>

A user-supplied program that compresses `py_image_layer` layer tars.

bsdtar pipes the archive through `tool` (via `--use-compress-program`), so any
program that reads an uncompressed stream on stdin and writes the compressed
stream to stdout works — including compressors libarchive has no filter for.

```starlark
py_layer_compressor(
    name = "pigz",
    tool = "//tools:pigz",
    args = ["-11"],
    extension = ".tar.gz",
)

py_layer_tier(
    name = "tier",
    groups = {"@pip//torch": "heavy"},
    compressors = {":pigz": "heavy"},
)
```

`extension` is the only claim available about the program's output, so it also
decides whether the layer is OCI-valid: anything but `.tar`, `.tar.gz` or
`.tar.zst` needs `allow_non_oci_layers = True` on the tier or rule.

The program runs inside the tar action, so prefer a Bazel-built binary or a
`sh_binary` wrapper over something assumed to be on the host's PATH.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_layer_compressor-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_layer_compressor-args"></a>args |  Arguments passed after the program path. Each entry must be a single whitespace-free token — bsdtar splits the command line itself.   | List of strings | optional |  `[]`  |
| <a id="py_layer_compressor-extension"></a>extension |  Extension for tars this compressor produces, e.g. '.tar.gz'. Must start with '.'. Also declares OCI validity: only '.tar', '.tar.gz' and '.tar.zst' are layer formats an image consumer can read.   | String | required |  |
| <a id="py_layer_compressor-tool"></a>tool |  The compressor program. Reads stdin, writes compressed bytes to stdout.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="py_layer_tier"></a>

## py_layer_tier

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_layer_tier")

py_layer_tier(<a href="#py_layer_tier-name">name</a>, <a href="#py_layer_tier-allow_non_oci_layers">allow_non_oci_layers</a>, <a href="#py_layer_tier-compression">compression</a>, <a href="#py_layer_tier-compressors">compressors</a>, <a href="#py_layer_tier-group">group</a>, <a href="#py_layer_tier-groups">groups</a>,
              <a href="#py_layer_tier-interpreter_group">interpreter_group</a>, <a href="#py_layer_tier-owner">owner</a>, <a href="#py_layer_tier-root">root</a>, <a href="#py_layer_tier-strip_prefix">strip_prefix</a>)
</pre>

Grouping and compression plan for `py_image_layer`.

Must not be testonly. `py_image_layer` transitions the `//py:layer_tier` flag to the tier, and the layer aspect reads that flag from every target it visits — including non-testonly ones outside the image, such as the interpreter toolchain and third-party installs. In a `package(default_testonly = True)`, set `testonly = False` on the tier.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_layer_tier-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_layer_tier-allow_non_oci_layers"></a>allow_non_oci_layers |  Permit compression the OCI image spec has no layer format for. The spec defines only tar, gzip and zstd; rules_oci labels anything else an uncompressed tar and records the compressed digest as the layer's diffid, so the image is invalid even though the build succeeds. Set this only when the tars are consumed by something other than an OCI image.   | Boolean | optional |  `False`  |
| <a id="py_layer_tier-compression"></a>compression |  Maps group name → [algorithm] or [algorithm, level]. Applies to every layer this tier names: the whole-group tar, each subpath-split tar, the multi-member merged tar, the interpreter tar, and first-party group tars.<br><br>`algorithm` is any bsdtar (libarchive) write filter: `none`, `gzip`, `bzip2`, `xz`, `lzma`, `lzop`, `lz4`, `lrzip`, `zstd`, or `compress`. `lzop` and `lrzip` shell out to a same-named binary that must exist inside the action — use `compressors` for a hermetic equivalent. `none` and `compress` take no level.<br><br>`level` is optional; omit it to take libarchive's default for that filter. Example: {"heavy_pkgs": ["zstd", "19"], "cold": ["xz"]}. Untouched groups default to gzip -6.   | <a href="https://bazel.build/rules/lib/core/dict">Dictionary: String -> List of strings</a> | optional |  `{}`  |
| <a id="py_layer_tier-compressors"></a>compressors |  Maps a `py_layer_compressor` target → group name, for compressors libarchive has no filter for. bsdtar pipes the layer through the program. A group may appear here or in `compression`, not both.   | <a href="https://bazel.build/rules/lib/core/dict">Dictionary: Label -> String</a> | optional |  `{}`  |
| <a id="py_layer_tier-group"></a>group |  Numeric gid owning every file in every layer this tier produces. Default: '0' (root).   | String | optional |  `"0"`  |
| <a id="py_layer_tier-groups"></a>groups |  Maps @pip//package → group name (whole pip package), @pip//package:glob → group name (pip subpath split), or //some/first_party:lib → group name (first-party PyInfo target). First-party main-repo labels may be written as //pkg:name; fully-qualified forms like @@//pkg:name are also accepted. A pip package may appear as a whole-package key OR with subpath globs, not both.   | <a href="https://bazel.build/rules/lib/core/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="py_layer_tier-interpreter_group"></a>interpreter_group |  When non-empty, the Python interpreter runfiles resolved from the binary's py toolchain are emitted as their own layer under this name instead of being bundled into the default source layer.   | String | optional |  `""`  |
| <a id="py_layer_tier-owner"></a>owner |  Numeric uid owning every file in every layer this tier produces. Default: '0' (root).   | String | optional |  `"0"`  |
| <a id="py_layer_tier-root"></a>root |  Root path in the image. Default: '/app'.   | String | optional |  `"/app"`  |
| <a id="py_layer_tier-strip_prefix"></a>strip_prefix |  Prefix stripped from source file paths. Empty means use the binary's short_path.   | String | optional |  `""`  |


<a id="py_library"></a>

## py_library

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_library")

py_library(<a href="#py_library-name">name</a>, <a href="#py_library-deps">deps</a>, <a href="#py_library-srcs">srcs</a>, <a href="#py_library-data">data</a>, <a href="#py_library-imports">imports</a>, <a href="#py_library-resolutions">resolutions</a>, <a href="#py_library-virtual_deps">virtual_deps</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_library-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_library-deps"></a>deps |  Targets that produce Python code, commonly `py_library` rules.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="py_library-srcs"></a>srcs |  Python source files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="py_library-data"></a>data |  Runtime dependencies of the program.<br><br>The transitive closure of the `data` dependencies will be available in the `.runfiles` folder for this binary/test. The program may optionally use the Runfiles lookup library to locate the data files, see https://pypi.org/project/bazel-runfiles/. Data is analyzed in the inherited caller configuration. Put artifacts that must match the terminal's Python environment in `deps`.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="py_library-imports"></a>imports |  List of import directories to be added to the PYTHONPATH.   | List of strings | optional |  `[]`  |
| <a id="py_library-resolutions"></a>resolutions |  Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it. See virtual_deps.   | Dictionary: String -> Label | optional |  `{}`  |
| <a id="py_library-virtual_deps"></a>virtual_deps |  -   | List of strings | optional |  `[]`  |


<a id="py_pex_binary"></a>

## py_pex_binary

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_pex_binary")

py_pex_binary(<a href="#py_pex_binary-name">name</a>, <a href="#py_pex_binary-binary">binary</a>, <a href="#py_pex_binary-inherit_path">inherit_path</a>, <a href="#py_pex_binary-inject_env">inject_env</a>, <a href="#py_pex_binary-python_interpreter_constraints">python_interpreter_constraints</a>,
              <a href="#py_pex_binary-python_shebang">python_shebang</a>)
</pre>

Build a pex executable from a py_binary

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_pex_binary-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_pex_binary-binary"></a>binary |  The py_binary target to package.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_pex_binary-inherit_path"></a>inherit_path |  Whether to inherit the `sys.path` (aka PYTHONPATH) of the environment that the binary runs in.<br><br>Use `false` to not inherit `sys.path`; use `fallback` to inherit `sys.path` after packaged dependencies; and use `prefer` to inherit `sys.path` before packaged dependencies.   | String | optional |  `""`  |
| <a id="py_pex_binary-inject_env"></a>inject_env |  Environment variables to set when running the pex binary.   | <a href="https://bazel.build/rules/lib/core/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="py_pex_binary-python_interpreter_constraints"></a>python_interpreter_constraints |  Python interpreter versions this PEX binary is compatible with. A list of semver strings. The placeholder strings `{major}`, `{minor}`, `{patch}` are substituted with the version of the `binary`'s own interpreter, the one the PEX is built for.   | List of strings | optional |  `["CPython=={major}.{minor}.*"]`  |
| <a id="py_pex_binary-python_shebang"></a>python_shebang |  -   | String | optional |  `"#!/usr/bin/env python3"`  |


<a id="py_unpacked_wheel"></a>

## py_unpacked_wheel

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_unpacked_wheel")

py_unpacked_wheel(<a href="#py_unpacked_wheel-name">name</a>, <a href="#py_unpacked_wheel-src">src</a>, <a href="#py_unpacked_wheel-console_scripts">console_scripts</a>, <a href="#py_unpacked_wheel-data_files">data_files</a>, <a href="#py_unpacked_wheel-namespace_entries">namespace_entries</a>, <a href="#py_unpacked_wheel-namespace_top_levels">namespace_top_levels</a>,
                  <a href="#py_unpacked_wheel-top_levels">top_levels</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_unpacked_wheel-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_unpacked_wheel-src"></a>src |  The Wheel file, as defined by https://packaging.python.org/en/latest/specifications/binary-distribution-format/#binary-distribution-format   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_unpacked_wheel-console_scripts"></a>console_scripts |  Console-script entry points declared by this wheel, in the form `"name=module:func"`.<br><br>`py_binary` consumes these via `PyWheelsInfo` to generate executable wrappers under `<venv>/bin/<name>`. Typically populated from the wheel's `*.dist-info/entry_points.txt` `[console_scripts]` section.   | List of strings | optional |  `[]`  |
| <a id="py_unpacked_wheel-data_files"></a>data_files |  PEP 427 `.data/data/` prefix-relative install paths (e.g. `share/foo/bar.txt`).<br><br>Venv assembly projects these into the venv prefix via `ctx.actions.symlink`. Typically populated by the `uv` wheel-install repo rule; hand-written `py_unpacked_wheel` targets may set it to expose data files shipped under the wheel's `<name>-<version>.data/data/` tree.<br><br>Must list the wheel's prefix tree **completely**. Assembly binds a whole directory with a single symlink when one wheel owns everything resolved beneath it, so an undeclared file sitting next to a declared one is still reachable under `sys.prefix` — an under-declared list changes which collisions are reported, not what the venv exposes.   | List of strings | optional |  `[]`  |
| <a id="py_unpacked_wheel-namespace_entries"></a>namespace_entries |  Concrete entries this wheel installs beneath its `namespace_top_levels`.<br><br>See the equivalent attribute on the `whl_install` rule for the full story; short version: `/`-joined paths like `jaraco/functools` that let venv assembly materialise a merged namespace directory out of per-entry symlinks, so static tools that inspect `site-packages/` directly see the package. When empty, namespace merging falls back to `.pth`-based resolution (runtime-only).   | List of strings | optional |  `[]`  |
| <a id="py_unpacked_wheel-namespace_top_levels"></a>namespace_top_levels |  Subset of `top_levels` that are PEP 420 namespace packages.<br><br>See the equivalent attribute on the `whl_install` rule for the full story; short version: names listed here suppress collision errors when multiple wheels claim the same top-level, because Python's namespace machinery is meant to merge their contributions.   | List of strings | optional |  `[]`  |
| <a id="py_unpacked_wheel-top_levels"></a>top_levels |  Complete list of immediate entries the wheel installs into site-packages.<br><br>When set, downstream rules can assemble a merged `site-packages/` tree via `ctx.actions.symlink` instead of relying on `.pth` entries. The list must include packages, modules, `.pth` files, and `*.dist-info` directories. If left empty (the default), other rules preserve the complete wheel root and fall back to `.pth`-based import resolution.<br><br>Typically populated by the `uv` wheel-install repo rule. Hand-written `py_unpacked_wheel` targets may populate this to opt into symlink-based venv assembly.   | List of strings | optional |  `[]`  |


<a id="whl_filegroup"></a>

## whl_filegroup

<pre>
load("@aspect_rules_py//py:defs.bzl", "whl_filegroup")

whl_filegroup(<a href="#whl_filegroup-name">name</a>, <a href="#whl_filegroup-pattern">pattern</a>, <a href="#whl_filegroup-runfiles">runfiles</a>, <a href="#whl_filegroup-whl">whl</a>)
</pre>

Extract files matching a regular expression from a wheel file.

An empty pattern will match all files.

Example usage:
```starlark
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_python//python:pip.bzl", "whl_filegroup")

whl_filegroup(
    name = "numpy_includes",
    pattern = "numpy/core/include/numpy",
    whl = "@pypi//numpy:whl",
)

cc_library(
    name = "numpy_headers",
    hdrs = [":numpy_includes"],
    includes = ["numpy_includes/numpy/core/include"],
    deps = ["@rules_python//python/cc:current_py_cc_headers"],
)

```

:::{seealso}

The `:extracted_whl_files` target, which is a filegroup of all the files
from the already extracted whl file.
:::

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="whl_filegroup-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="whl_filegroup-pattern"></a>pattern |  Only file paths matching this regex pattern will be extracted.   | String | optional |  `""`  |
| <a id="whl_filegroup-runfiles"></a>runfiles |  Whether to include the output TreeArtifact in this target's runfiles.   | Boolean | optional |  `False`  |
| <a id="whl_filegroup-whl"></a>whl |  The wheel to extract files from.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="PyInfo"></a>

## PyInfo

<pre>
load("@aspect_rules_py//py:defs.bzl", "PyInfo")

PyInfo(<a href="#PyInfo-transitive_sources">transitive_sources</a>, <a href="#PyInfo-imports">imports</a>, <a href="#PyInfo-virtual_dependencies">virtual_dependencies</a>, <a href="#PyInfo-virtual_resolutions">virtual_resolutions</a>)
</pre>

Python source, import-path, and virtual-dependency information for a target's dependency closure.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="PyInfo-transitive_sources"></a>transitive_sources |  depset[File] — postorder depset of first-party `.py` sources in the transitive closure.    |
| <a id="PyInfo-imports"></a>imports |  depset[str] — import roots to place on `sys.path` (rlocation-root-relative).    |
| <a id="PyInfo-virtual_dependencies"></a>virtual_dependencies |  depset[str] — names of required virtual dependencies, independent of their resolution status.    |
| <a id="PyInfo-virtual_resolutions"></a>virtual_resolutions |  depset[struct(virtual, target)] — virtual-dependency-name to concrete-target resolutions.    |


<a id="PyLayerCompressorInfo"></a>

## PyLayerCompressorInfo

<pre>
load("@aspect_rules_py//py:defs.bzl", "PyLayerCompressorInfo")

PyLayerCompressorInfo(<a href="#PyLayerCompressorInfo-args">args</a>, <a href="#PyLayerCompressorInfo-executable">executable</a>, <a href="#PyLayerCompressorInfo-extension">extension</a>, <a href="#PyLayerCompressorInfo-files_to_run">files_to_run</a>)
</pre>

A custom layer compressor: a program bsdtar pipes the archive through.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="PyLayerCompressorInfo-args"></a>args |  tuple[str] — arguments appended after the program path.    |
| <a id="PyLayerCompressorInfo-executable"></a>executable |  File — the program bsdtar invokes via --use-compress-program.    |
| <a id="PyLayerCompressorInfo-extension"></a>extension |  str — output file extension, e.g. '.tar.br'.    |
| <a id="PyLayerCompressorInfo-files_to_run"></a>files_to_run |  FilesToRunProvider — the program plus its runfiles, for the tar action's `tools`.    |


<a id="PyLayerTierInfo"></a>

## PyLayerTierInfo

<pre>
load("@aspect_rules_py//py:defs.bzl", "PyLayerTierInfo")

PyLayerTierInfo(<a href="#PyLayerTierInfo-whole_groups">whole_groups</a>, <a href="#PyLayerTierInfo-subpath_groups">subpath_groups</a>, <a href="#PyLayerTierInfo-compression">compression</a>, <a href="#PyLayerTierInfo-compressors">compressors</a>, <a href="#PyLayerTierInfo-codecs">codecs</a>, <a href="#PyLayerTierInfo-multi_member_groups">multi_member_groups</a>,
                <a href="#PyLayerTierInfo-interpreter_group">interpreter_group</a>, <a href="#PyLayerTierInfo-root">root</a>, <a href="#PyLayerTierInfo-strip_prefix">strip_prefix</a>, <a href="#PyLayerTierInfo-owner">owner</a>, <a href="#PyLayerTierInfo-group">group</a>)
</pre>

Layer tier for py_image_layer: how pip packages are grouped and compressed.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="PyLayerTierInfo-whole_groups"></a>whole_groups |  dict[str, str] — normalized pip label → group name.    |
| <a id="PyLayerTierInfo-subpath_groups"></a>subpath_groups |  dict[str, dict[str, list[str]]] — label → {group_name: [glob_patterns]}.    |
| <a id="PyLayerTierInfo-compression"></a>compression |  dict[str, list[str]] — group name → [algorithm, level], as written on the rule.    |
| <a id="PyLayerTierInfo-compressors"></a>compressors |  dict[str, PyLayerCompressorInfo] — group name → custom compressor.    |
| <a id="PyLayerTierInfo-codecs"></a>codecs |  dict[str, struct] — group name → resolved codec (bsdtar flags + file extension).    |
| <a id="PyLayerTierInfo-multi_member_groups"></a>multi_member_groups |  dict[str, True] — group names with 2+ members in whole_groups.    |
| <a id="PyLayerTierInfo-interpreter_group"></a>interpreter_group |  str — group name for the Python interpreter layer; '' disables.    |
| <a id="PyLayerTierInfo-root"></a>root |  str — root path in the image (e.g. '/app').    |
| <a id="PyLayerTierInfo-strip_prefix"></a>strip_prefix |  str — prefix stripped from source file paths; empty means use binary short_path.    |
| <a id="PyLayerTierInfo-owner"></a>owner |  str — numeric uid owning files in the layer.    |
| <a id="PyLayerTierInfo-group"></a>group |  str — numeric gid owning files in the layer.    |


<a id="PyRuntimeInfo"></a>

## PyRuntimeInfo

<pre>
load("@aspect_rules_py//py:defs.bzl", "PyRuntimeInfo")

PyRuntimeInfo(*, <a href="#PyRuntimeInfo-implementation_name">implementation_name</a>, <a href="#PyRuntimeInfo-interpreter_path">interpreter_path</a>, <a href="#PyRuntimeInfo-interpreter">interpreter</a>, <a href="#PyRuntimeInfo-files">files</a>, <a href="#PyRuntimeInfo-coverage_tool">coverage_tool</a>,
              <a href="#PyRuntimeInfo-coverage_files">coverage_files</a>, <a href="#PyRuntimeInfo-pyc_tag">pyc_tag</a>, <a href="#PyRuntimeInfo-python_version">python_version</a>, <a href="#PyRuntimeInfo-stub_shebang">stub_shebang</a>, <a href="#PyRuntimeInfo-bootstrap_template">bootstrap_template</a>,
              <a href="#PyRuntimeInfo-interpreter_version_info">interpreter_version_info</a>, <a href="#PyRuntimeInfo-stage2_bootstrap_template">stage2_bootstrap_template</a>, <a href="#PyRuntimeInfo-zip_main_template">zip_main_template</a>, <a href="#PyRuntimeInfo-abi_flags">abi_flags</a>,
              <a href="#PyRuntimeInfo-site_init_template">site_init_template</a>, <a href="#PyRuntimeInfo-supports_build_time_venv">supports_build_time_venv</a>)
</pre>

Contains information about a Python runtime, as returned by the `py_runtime`
rule.

:::{warning}
This is an **unstable public** API. It may change more frequently and has weaker
compatibility guarantees.
:::

A Python runtime describes either a *platform runtime* or an *in-build runtime*.
A platform runtime accesses a system-installed interpreter at a known path,
whereas an in-build runtime points to a `File` that acts as the interpreter. In
both cases, an "interpreter" is really any executable binary or wrapper script
that is capable of running a Python script passed on the command line, following
the same conventions as the standard CPython interpreter.

**FIELDS**

| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="PyRuntimeInfo-implementation_name"></a>implementation_name | :type: str \| None<br><br>The Python implementation name (`sys.implementation.name`) | `None` |
| <a id="PyRuntimeInfo-interpreter_path"></a>interpreter_path | :type: str \| None<br><br>If this is a platform runtime, this field is the absolute filesystem path to the interpreter on the target platform. Otherwise, this is `None`. | `None` |
| <a id="PyRuntimeInfo-interpreter"></a>interpreter | :type: File \| None<br><br>If this is an in-build runtime, this field is a `File` representing the interpreter. Otherwise, this is `None`. Note that an in-build runtime can use either a prebuilt, checked-in interpreter or an interpreter built from source. | `None` |
| <a id="PyRuntimeInfo-files"></a>files | :type: depset[File] \| None<br><br>If this is an in-build runtime, this field is a `depset` of `File`s that need to be added to the runfiles of an executable target that uses this runtime (in particular, files needed by `interpreter`). The value of `interpreter` need not be included in this field. If this is a platform runtime then this field is `None`. | `None` |
| <a id="PyRuntimeInfo-coverage_tool"></a>coverage_tool | :type: File \| None<br><br>If set, this field is a `File` representing tool used for collecting code coverage information from python tests. Otherwise, this is `None`. | `None` |
| <a id="PyRuntimeInfo-coverage_files"></a>coverage_files | :type: depset[File] \| None<br><br>The files required at runtime for using `coverage_tool`. Will be `None` if no `coverage_tool` was provided. | `None` |
| <a id="PyRuntimeInfo-pyc_tag"></a>pyc_tag | :type: str \| None<br><br>The tag portion of a pyc filename, e.g. the `cpython-39` infix of `foo.cpython-39.pyc`. See PEP 3147. If not specified, it will be computed from {obj}`implementation_name` and {obj}`interpreter_version_info`. If no pyc_tag is available, then only source-less pyc generation will function correctly. | `None` |
| <a id="PyRuntimeInfo-python_version"></a>python_version | :type: str<br><br>Indicates whether this runtime uses Python major version 2 or 3. Valid values are (only) `"PY2"` and `"PY3"`. | none |
| <a id="PyRuntimeInfo-stub_shebang"></a>stub_shebang | :type: str<br><br>"Shebang" expression prepended to the bootstrapping Python stub script used when executing {obj}`py_binary` targets.  Does not apply to Windows. | `None` |
| <a id="PyRuntimeInfo-bootstrap_template"></a>bootstrap_template | :type: File<br><br>A template of code responsible for the initial startup of a program.<br><br>This code is responsible for:<br><br>* Locating the target interpreter. Typically it is in runfiles, but not always. * Setting necessary environment variables, command line flags, or other   configuration that can't be modified after the interpreter starts. * Invoking the appropriate entry point. This is usually a second-stage bootstrap   that performs additional setup prior to running a program's actual entry point.<br><br>The {obj}`--bootstrap_impl` flag affects how this stage 1 bootstrap is expected to behave and the substutitions performed.<br><br>* `--bootstrap_impl=system_python` substitutions: `%is_zipfile%`, `%python_binary%`,   `%target%`, `%workspace_name`, `%coverage_tool%`, `%import_all%`, `%imports%`,   `%main%`, `%shebang%` * `--bootstrap_impl=script` substititions: `%is_zipfile%`, `%python_binary%`,   `%python_binary_actual%`, `%target%`, `%workspace_name`,   `%shebang%`, `%stage2_bootstrap%`<br><br>Substitution definitions:<br><br>* `%shebang%`: The shebang to use with the bootstrap; the bootstrap template   may choose to ignore this. * `%stage2_bootstrap%`: A runfiles-relative path to the stage 2 bootstrap. * `%python_binary%`: The path to the target Python interpreter. There are three   types of paths:   * An absolute path to a system interpreter (e.g. begins with `/`).   * A runfiles-relative path to an interpreter (e.g. `somerepo/bin/python3`)   * A program to search for on PATH, i.e. a word without spaces, e.g. `python3`.<br><br>  When `--bootstrap_impl=script` is used, this is always a runfiles-relative   path to a venv-based interpreter executable.<br><br>* `%python_binary_actual%`: The path to the interpreter that   `%python_binary%` invokes. There are three types of paths:   * An absolute path to a system interpreter (e.g. begins with `/`).   * A runfiles-relative path to an interpreter (e.g. `somerepo/bin/python3`)   * A program to search for on PATH, i.e. a word without spaces, e.g. `python3`.<br><br>  Only set for zip builds with `--bootstrap_impl=script`; other builds will use   an empty string.<br><br>* `%workspace_name%`: The name of the workspace the target belongs to. * `%is_zipfile%`: The string `1` if this template is prepended to a zipfile to   create a self-executable zip file. The string `0` otherwise.<br><br>For the other substitution definitions, see the {obj}`stage2_bootstrap_template` docs.<br><br>:::{versionchanged} 0.33.0 The set of substitutions depends on {obj}`--bootstrap_impl` ::: | `None` |
| <a id="PyRuntimeInfo-interpreter_version_info"></a>interpreter_version_info | :type: struct<br><br>Version information about the interpreter this runtime provides. It should match the format given by `sys.version_info`, however for simplicity, the micro, releaselevel, and serial values are optional. A struct with the following fields: * `major`: {type}`int`, the major version number * `minor`: {type}`int`, the minor version number * `micro`: {type}`int \| None`, the micro version number * `releaselevel`: {type}`str \| None`, the release level * `serial`: {type}`int \| None`, the serial number of the release | `None` |
| <a id="PyRuntimeInfo-stage2_bootstrap_template"></a>stage2_bootstrap_template | :type: File<br><br>A template of Python code that runs under the desired interpreter and is responsible for orchestrating calling the program's actual main code. This bootstrap is responsible for affecting the current runtime's state, such as import paths or enabling coverage, so that, when it runs the program's actual main code, it works properly under Bazel.<br><br>The following substitutions are made during template expansion: * `%main%`: A runfiles-relative path to the program's actual main file. This   can be a `.py` or `.pyc` file, depending on precompile settings. * `%coverage_tool%`: Runfiles-relative path to the coverage library's entry point.   If coverage is not enabled or available, an empty string. * `%import_all%`: The string `True` if all repositories in the runfiles should   be added to sys.path. The string `False` otherwise. * `%imports%`: A colon-delimited string of runfiles-relative paths to add to   sys.path. * `%target%`: The name of the target this is for. * `%workspace_name%`: The name of the workspace the target belongs to.<br><br>:::{versionadded} 0.33.0 ::: | `None` |
| <a id="PyRuntimeInfo-zip_main_template"></a>zip_main_template | :type: File<br><br>A template of Python code that becomes a zip file's top-level `__main__.py` file. The top-level `__main__.py` file is used when the zip file is explicitly passed to a Python interpreter. See PEP 441 for more information about zipapp support. Note that py_binary-generated zip files are self-executing and skip calling `__main__.py`.<br><br>The following substitutions are made during template expansion: * `%stage2_bootstrap%`: A runfiles-relative string to the stage 2 bootstrap file. * `%python_binary%`: The path to the target Python interpreter. There are three   types of paths:   * An absolute path to a system interpreter (e.g. begins with `/`).   * A runfiles-relative path to an interpreter (e.g. `somerepo/bin/python3`)   * A program to search for on PATH, i.e. a word without spaces, e.g. `python3`. * `%workspace_name%`: The name of the workspace for the built target.<br><br>:::{versionadded} 0.33.0 ::: | `None` |
| <a id="PyRuntimeInfo-abi_flags"></a>abi_flags | :type: str<br><br>The runtime's ABI flags, i.e. `sys.abiflags`.<br><br>:::{versionadded} 1.0.0 ::: | `""` |
| <a id="PyRuntimeInfo-site_init_template"></a>site_init_template | :type: File<br><br>The template to use for the binary-specific site-init hook run by the interpreter at startup.<br><br>:::{versionadded} 1.0.0 ::: | `None` |
| <a id="PyRuntimeInfo-supports_build_time_venv"></a>supports_build_time_venv | :type: bool<br><br>True if this toolchain supports the build-time created virtual environment. False if not or unknown. If build-time venv creation isn't supported, then binaries may fallback to non-venv solutions or creating a venv at runtime.<br><br>In order to use the build-time created virtual environment, a toolchain needs to meet two criteria: 1. Specifying the underlying executable (e.g. `/usr/bin/python3`, as reported by    `sys._base_executable`) for the venv executable (`$venv/bin/python3`, as reported    by `sys.executable`). This typically requires relative symlinking the venv    path to the underlying path at build time, or using the `PYTHONEXECUTABLE`    environment variable (Python 3.11+) at runtime. 2. Having the build-time created site-packages directory    (`<venv>/lib/python{version}/site-packages`) recognized by the runtime    interpreter. This typically requires the Python version to be known at    build-time and match at runtime.<br><br>:::{versionadded} 1.5.0 ::: | `True` |


<a id="PyWheelsInfo"></a>

## PyWheelsInfo

<pre>
load("@aspect_rules_py//py:defs.bzl", "PyWheelsInfo")

PyWheelsInfo(<a href="#PyWheelsInfo-wheels">wheels</a>)
</pre>

Installed wheel records used by venv assembly and image layering.

Each element of `wheels` describes one wheel in the transitive closure of a
target. Every record carries the complete installed tree. Repository-inspected
wheels also carry their site-packages layout and console scripts; source-built
wheels may leave that analysis-time metadata empty.

Venv rules project known layouts and generate console-script wrappers. Image
rules use `install_tree` to retain each wheel as a package leaf independently
of whether its metadata was available during analysis.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="PyWheelsInfo-wheels"></a>wheels |  Depset of wheel record structs, one per wheel in the transitive closure. rules_py aggregates this field in postorder. Producers must use `default` or `postorder`, the orders Bazel permits in that aggregate. For collision classes that select one claimant, permissive handling gives the later distinct element in the flattened sequence precedence. Duplicate dependency edges do not create another precedence position. Fields:   * `top_levels`: tuple[str] — complete set of immediate `site-packages`     entry names when nonempty; an empty tuple means the layout is unknown.   * `top_level_dirs`: tuple[str] — subset of non-metadata top_levels that     are directories in the RECORD-derived install tree rather than single-file     modules.   * `namespace_top_levels`: tuple[str] — subset of top_levels that are PEP 420 namespace packages.   * `namespace_entries`: tuple[str] — `/`-joined paths of the concrete entries beneath     the namespace top-levels (e.g. `jaraco/functools`), used to materialise a merged     namespace directory out of per-entry symlinks. May be absent on structs from     older producers; consumers use `getattr` with a `()` default.   * `namespace_dirs`: tuple[str] — implicit-namespace directory skeleton under the     namespace top-levels (site-packages-relative `/`-joined paths). May be absent     on structs from older producers; consumers use `getattr` with a `()` default.   * `regular_roots`: tuple[str] — minimal directories under the namespace     top-levels carrying an `__init__.py`. Cross-referencing a wheel's     `regular_roots` with another wheel's `namespace_dirs` detects regular     packages spanning wheels, which venv assembly must physically merge.     May be absent on structs from older producers.   * `native_roots`: tuple[str] — collision-relevant top-level directories,     namespace directories, and regular roots containing RECORD entries with     native-library suffixes. A colliding root in this set cannot be copied     into a merge tree without changing the library's physical origin.   * `site_packages_rfpath`: str — runfiles-root-relative path to the wheel's site-packages.   * `console_scripts`: tuple[str] — entry points encoded as `"name=module:func"`.   * `data_files`: tuple[str] — PEP 427 `.data/data/` prefix-relative install     paths (e.g. `share/jupyter/...`), projected into the venv prefix. Must     enumerate the wheel's prefix tree completely: venv assembly binds a whole     directory when one wheel owns everything resolved beneath it, so an     undeclared sibling file in that directory is still exposed under     `sys.prefix`. Validated by `make_wheel_record`. May be absent on structs     from older producers; consumers use `getattr` with `()`.   * `install_tree`: File — complete installed wheel tree.   * `tl_claims`, `metadata_top_levels`, `cs_claims`: derived fields     precomputed by `make_wheel_record` so venv assembly's collision     resolution does per-wheel parsing once instead of per consuming binary.     Each `tl_claims` entry carries the top-level's namespace, directory,     native-root, namespace-entry, and namespace-directory facts.<br><br>Records must be built with `make_wheel_record` so the derived fields are present and consistent with the raw ones.    |


<a id="py_binary"></a>

## py_binary

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(<a href="#py_binary-name">name</a>, <a href="#py_binary-srcs">srcs</a>, <a href="#py_binary-main">main</a>, <a href="#py_binary-kwargs">**kwargs</a>)
</pre>

Build and run a Python binary.

Splits the call into a sibling `py_venv` (which carries srcs / deps
/ imports / virtual_deps / resolutions / package_collisions /
include_*_site_packages / interpreter_options) plus a thin launcher
rule that exec's that venv's interpreter. Set `expose_venv = True`
to make the sibling a first-class `:{name}.venv` target — runnable
(`bazel run :{name}.venv` drops into the hermetic interpreter) and
pairable with `py_venv_link` for IDE integration. For the common
case where you want both the venv target *and* an IDE-pointable
workspace symlink in one step, set `expose_venv_link = True`.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_binary-name"></a>name |  Name of the rule.   |  none |
| <a id="py_binary-srcs"></a>srcs |  Python source files.   |  `[]` |
| <a id="py_binary-main"></a>main |  Entry point. Like rules_python, this is treated as a suffix of a file that should appear among the srcs. If absent, then `[name].py` is tried. As a final fallback, if the srcs has a single file, that is used as the main.<br><br>Note: the fallback runs at macro-evaluation time and operates on label strings, not resolved files — it cannot inspect a generated target's output basename. If `main` would resolve to a file produced by another rule (e.g. a `genrule` whose output happens to be `<name>.py`), the macro can't see that and you must pass `main =` explicitly.   |  `None` |
| <a id="py_binary-kwargs"></a>kwargs |  additional named parameters forwarded to the underlying rule and the sibling py_venv. Two extras are handled by this macro:<br><br>* `expose_venv` (bool, default `False`) — when `True`, emit   a sibling `:{name}.venv` py_venv carrying all venv-shaping   attrs (deps, imports, package_collisions,   include_*_site_packages, interpreter_options). The `.venv`   target is runnable (`bazel run :{name}.venv` drops into   the hermetic interpreter). * `expose_venv_link` (bool, default `False`) — when `True`,   additionally emit a `:{name}.venv_link` py_venv_link.   `bazel run :{name}.venv_link` links the target's runfiles   tree into the workspace and prints the nested venv path   suitable for an IDE's interpreter setting. Implies   `expose_venv = True`; passing   `expose_venv = False, expose_venv_link = True` explicitly   is rejected with a clear error. Equivalent to declaring an   explicit   `py_venv_link(name = "{name}.venv_link", venv = ":{name}.venv")`   alongside the binary.   |  none |


<a id="py_image_layer"></a>

## py_image_layer

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_image_layer")

py_image_layer(<a href="#py_image_layer-name">name</a>, <a href="#py_image_layer-binary">binary</a>, <a href="#py_image_layer-groups">groups</a>, <a href="#py_image_layer-group_execution_requirements">group_execution_requirements</a>, <a href="#py_image_layer-group_compress_levels">group_compress_levels</a>,
               <a href="#py_image_layer-group_compression">group_compression</a>, <a href="#py_image_layer-group_compressors">group_compressors</a>, <a href="#py_image_layer-allow_non_oci_layers">allow_non_oci_layers</a>,
               <a href="#py_image_layer-warn_remote_cache_threshold_mb">warn_remote_cache_threshold_mb</a>, <a href="#py_image_layer-warn_layer_count">warn_layer_count</a>, <a href="#py_image_layer-platform">platform</a>, <a href="#py_image_layer-layer_tier">layer_tier</a>, <a href="#py_image_layer-launcher_dir">launcher_dir</a>,
               <a href="#py_image_layer-binaries">binaries</a>, <a href="#py_image_layer-kwargs">**kwargs</a>)
</pre>

Create OCI-compatible tars from one or more py_binary targets.

Pip-package grouping + compression is resolved from the `//py:layer_tier`
label_flag. Override globally with `--//py:layer_tier=//path:custom_tier`,
or pin a tier to a specific rule via the `py_layer_tier` attr below.

## Output layers

  1. Non-pip deps listed in `groups` → one rule-created tar per group.
  2. First-party py_library targets matched by `py_layer_tier.groups` → one
     rule-created tar per group (aggregated across all matched targets in the
     binary inputs' dep closures).
  3. Solo-group and subpath-split pip tars — built by `_layer_aspect` at each pip
     target's own namespace; globally shared across every rule using that package.
  4. Multi-member merged tars — action-shared for a single binary or one per
     group from the closure-filtered union across multiple binaries.
  5. Ungrouped pip packages → one squashed rule-created tar.
  6. Remaining first-party Python source files → the "default" layer.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_image_layer-name"></a>name |  Name of the generated target.   |  none |
| <a id="py_image_layer-binary"></a>binary |  A py_binary target.   |  `None` |
| <a id="py_image_layer-groups"></a>groups |  Maps a NON-PIP dep label to a group name. Each gets its own rule-created tar. All pip-package grouping (whole-package, subpath, multi-member) belongs in py_layer_tier — subpath glob keys passed here fail loudly.   |  `{}` |
| <a id="py_image_layer-group_execution_requirements"></a>group_execution_requirements |  Maps a group name to execution requirement strings. The group name "packages" applies to the squashed ungrouped-pip tar.   |  `{}` |
| <a id="py_image_layer-group_compress_levels"></a>group_compress_levels |  gzip-only shorthand: maps a group name to a compression level (1-9) for rule-created tars. Default 6. Ignored for any group named by `group_compression`, `group_compressors`, or the tier's `compression`.   |  `{}` |
| <a id="py_image_layer-group_compression"></a>group_compression |  Maps a group name to `[algorithm]` or `[algorithm, level]` for rule-created tars (non-pip deps, first-party groups, the squashed ungrouped-pip tar under the name "packages", and the source layer under the name "default"). `algorithm` is any bsdtar write filter — `none`, `gzip`, `bzip2`, `xz`, `lzma`, `lzop`, `lz4`, `lrzip`, `zstd`, `compress`. Takes precedence over the tier's `compression` for the same group. Does NOT apply to aspect-created pip tars; configure those on the py_layer_tier target.   |  `{}` |
| <a id="py_image_layer-group_compressors"></a>group_compressors |  Maps a `py_layer_compressor` target to a group name, for rule-created tars that need a compressor libarchive has no filter for. Same precedence as `group_compression`; a group may appear in one or the other, not both.   |  `{}` |
| <a id="py_image_layer-allow_non_oci_layers"></a>allow_non_oci_layers |  Permit compression the OCI image spec has no layer format for. The spec defines only tar, gzip and zstd, and rules_oci labels anything else an uncompressed tar with the compressed digest as its diffid — the build succeeds and the image is invalid. Set this only when the tars are consumed by something other than an OCI image.   |  `False` |
| <a id="py_image_layer-warn_remote_cache_threshold_mb"></a>warn_remote_cache_threshold_mb |  Threshold for large package warnings.   |  `200` |
| <a id="py_image_layer-warn_layer_count"></a>warn_layer_count |  Warn when total layers exceed this. Default: 90.   |  `90` |
| <a id="py_image_layer-platform"></a>platform |  Platform transition target.   |  `None` |
| <a id="py_image_layer-layer_tier"></a>layer_tier |  Optional py_layer_tier target pinned for this rule. Sets the `@aspect_rules_py//py:layer_tier` label_flag via the rule transition, overriding any command-line value for this rule's subgraph.   |  `None` |
| <a id="py_image_layer-launcher_dir"></a>launcher_dir |  Absolute image directory for the binary launchers. Defaults to /app/bin with multiple binaries. Set RUNFILES_DIR=/app.runfiles in the image.   |  `""` |
| <a id="py_image_layer-binaries"></a>binaries |  Alternative to binary. A nonempty list of py_binary targets to include in the image.   |  `None` |
| <a id="py_image_layer-kwargs"></a>kwargs |  Forwarded to inner rule.   |  none |


<a id="py_pytest_main"></a>

## py_pytest_main

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_pytest_main")

py_pytest_main(<a href="#py_pytest_main-name">name</a>, <a href="#py_pytest_main-py_library">py_library</a>, <a href="#py_pytest_main-deps">deps</a>, <a href="#py_pytest_main-data">data</a>, <a href="#py_pytest_main-testonly">testonly</a>, <a href="#py_pytest_main-kwargs">**kwargs</a>)
</pre>

py_pytest_main wraps the template rendering target and the final py_library.

Low-level escape hatch: prefer [py_pytest_test](#py_pytest_test) for pytest
suites. Use this only for hand-written or wrapped entrypoints (e.g. exposing
an importable `main()` for custom setup/teardown around pytest).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_pytest_main-name"></a>name |  The name of the runable target that updates the test entry file.   |  none |
| <a id="py_pytest_main-py_library"></a>py_library |  Use this attribute to override the default py_library rule.   |  `<rule py_library>` |
| <a id="py_pytest_main-deps"></a>deps |  A list containing the pytest library target, e.g., @pypi_pytest//:pkg.   |  `[]` |
| <a id="py_pytest_main-data"></a>data |  A list of data dependencies to pass to the py_library target.   |  `[]` |
| <a id="py_pytest_main-testonly"></a>testonly |  A boolean indicating if the py_library target is testonly.   |  `True` |
| <a id="py_pytest_main-kwargs"></a>kwargs |  The extra arguments passed to the template rendering target.   |  none |


<a id="py_pytest_test"></a>

## py_pytest_test

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_pytest_test")

py_pytest_test(<a href="#py_pytest_test-name">name</a>, <a href="#py_pytest_test-srcs">srcs</a>, <a href="#py_pytest_test-deps">deps</a>, <a href="#py_pytest_test-pytest_args">pytest_args</a>, <a href="#py_pytest_test-chdir">chdir</a>, <a href="#py_pytest_test-resolutions">resolutions</a>, <a href="#py_pytest_test-kwargs">**kwargs</a>)
</pre>

A `py_test` that always runs under pytest.

Pytest is always the driver, so the entrypoint wiring is unambiguous.
Include the `pytest` package (and `coverage`, if you want coverage) in
`deps`.

Every file in `srcs` is a test module that pytest collects (scoped to the
target, not the whole runfiles tree). Put importable support code in `deps`
and pytest's `conftest.py` in `data`; to select tests by name pattern, use
Bazel's `glob()` in the `srcs` list.

If a package directory here shares its name with a distribution in `deps`,
see the module docs above: pytest may name test modules by a truncated path
and shadow that distribution for the code under test. `consider_namespace_packages`
(pytest 8.1+), via `env` or `pytest_args`, is the fix.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_pytest_test-name"></a>name |  Name of the rule.   |  none |
| <a id="py_pytest_test-srcs"></a>srcs |  Python test source files; pytest collects exactly these.   |  `[]` |
| <a id="py_pytest_test-deps"></a>deps |  Dependencies; must include the pytest package (e.g. `@pypi_pytest//:pkg`).   |  `[]` |
| <a id="py_pytest_test-pytest_args"></a>pytest_args |  Extra arguments baked into the pytest invocation. Setting this renders a private per-test entrypoint instead of reusing the shared main.   |  `[]` |
| <a id="py_pytest_test-chdir"></a>chdir |  Optional directory to change into before pytest runs, relative to the runfiles root. Also forces a private per-test entrypoint.   |  `None` |
| <a id="py_pytest_test-resolutions"></a>resolutions |  virtual-dep resolutions, a dict of virtual dependency name to the label of an installed package providing it.   |  `None` |
| <a id="py_pytest_test-kwargs"></a>kwargs |  forwarded to the underlying test rule and sibling py_venv.   |  none |


<a id="py_runtime"></a>

## py_runtime

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_runtime")

py_runtime(<a href="#py_runtime-attrs">**attrs</a>)
</pre>

Creates an executable Python program.

This is the public macro wrapping the underlying rule. Args are forwarded
on as-is unless otherwise specified. See
{rule}`py_runtime`
for detailed attribute documentation.

This macro affects the following args:
* `python_version`: cannot be `PY2`
* `srcs_version`: cannot be `PY2` or `PY2ONLY`
* `tags`: May have special marker values added, if not already present.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_runtime-attrs"></a>attrs |  Rule attributes forwarded onto {rule}`py_runtime`.   |  none |


<a id="py_runtime_pair"></a>

## py_runtime_pair

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_runtime_pair")

py_runtime_pair(<a href="#py_runtime_pair-name">name</a>, <a href="#py_runtime_pair-py2_runtime">py2_runtime</a>, <a href="#py_runtime_pair-py3_runtime">py3_runtime</a>, <a href="#py_runtime_pair-attrs">**attrs</a>)
</pre>

A toolchain rule for Python.

This is a macro around the underlying {rule}`py_runtime_pair` rule.

This used to wrap up to two Python runtimes, one for Python 2 and one for Python 3.
However, Python 2 is no longer supported, so it now only wraps a single Python 3
runtime.

Usually the wrapped runtimes are declared using the `py_runtime` rule, but any
rule returning a `PyRuntimeInfo` provider may be used.

This rule returns a `platform_common.ToolchainInfo` provider with the following
schema:

```python
platform_common.ToolchainInfo(
    py2_runtime = None,
    py3_runtime = <PyRuntimeInfo or None>,
)
```

Example usage:

```python
# In your BUILD file...

load("@rules_python//python:py_runtime.bzl", "py_runtime")
load("@rules_python//python:py_runtime_pair.bzl", "py_runtime_pair")

py_runtime(
    name = "my_py3_runtime",
    interpreter_path = "/system/python3",
    python_version = "PY3",
)

py_runtime_pair(
    name = "my_py_runtime_pair",
    py3_runtime = ":my_py3_runtime",
)

toolchain(
    name = "my_toolchain",
    target_compatible_with = <...>,
    toolchain = ":my_py_runtime_pair",
    toolchain_type = "@rules_python//python:toolchain_type",
)
```

```python
# In your WORKSPACE...

register_toolchains("//my_pkg:my_toolchain")
```


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_runtime_pair-name"></a>name |  str, the name of the target   |  none |
| <a id="py_runtime_pair-py2_runtime"></a>py2_runtime |  optional Label; must be unset or None; an error is raised otherwise.   |  `None` |
| <a id="py_runtime_pair-py3_runtime"></a>py3_runtime |  Label; a target with `PyRuntimeInfo` for Python 3.   |  `None` |
| <a id="py_runtime_pair-attrs"></a>attrs |  Extra attrs passed onto the native rule   |  none |


<a id="py_test"></a>

## py_test

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_test")

py_test(<a href="#py_test-name">name</a>, <a href="#py_test-srcs">srcs</a>, <a href="#py_test-main">main</a>, <a href="#py_test-kwargs">**kwargs</a>)
</pre>

Identical to [py_binary](#function-py_binary), but produces a target that can be used with `bazel test`.

`py_test` is a generic test rule: it runs a Python file as a test, nothing
more. To drive a suite with a framework, use the purpose-oriented macros
[py_pytest_test](#py_pytest_test) (pytest) or
[py_unittest_test](#py_unittest_test) (stdlib unittest).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_test-name"></a>name |  Name of the rule.   |  none |
| <a id="py_test-srcs"></a>srcs |  Python source files.   |  `[]` |
| <a id="py_test-main"></a>main |  Entry point. This is treated as a suffix of a file that should appear among the srcs. If absent, then `[name].py` is tried. As a final fallback, if the srcs has a single file, that is used as the main.   |  `None` |
| <a id="py_test-kwargs"></a>kwargs |  additional named parameters forwarded to the underlying rule and the sibling py_venv.   |  none |


<a id="py_unittest_test"></a>

## py_unittest_test

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_unittest_test")

py_unittest_test(<a href="#py_unittest_test-name">name</a>, <a href="#py_unittest_test-srcs">srcs</a>, <a href="#py_unittest_test-deps">deps</a>, <a href="#py_unittest_test-resolutions">resolutions</a>, <a href="#py_unittest_test-kwargs">**kwargs</a>)
</pre>

A `py_test` that runs under the stdlib `unittest` framework.

Loads each `srcs` file and collects its `unittest.TestCase`s. Integrates
with Bazel coverage, sharding, JUnit XML, and `--test_filter`. No pytest
dependency required.

Every file in `srcs` is a test module. Put importable support code in
`deps`; to select tests by name pattern, use Bazel's `glob()` in the `srcs`
list.

Runtime `args` are parsed by the driver: `-v`/`-q`, `-f`/`--failfast`,
`-b`/`--buffer`, and `-k PATTERN` (native unittest `-k`: repeatable,
ORed, `*` is fnmatch). Unknown args are rejected rather than ignored.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_unittest_test-name"></a>name |  Name of the rule.   |  none |
| <a id="py_unittest_test-srcs"></a>srcs |  Python test source files; each is loaded as a test module.   |  `[]` |
| <a id="py_unittest_test-deps"></a>deps |  Dependencies. `coverage` is required only for coverage; JUnit XML is emitted by a built-in writer, so no third-party runner is needed.   |  `[]` |
| <a id="py_unittest_test-resolutions"></a>resolutions |  virtual-dep resolutions, a dict of virtual dependency name to the label of an installed package providing it.   |  `None` |
| <a id="py_unittest_test-kwargs"></a>kwargs |  forwarded to the underlying test rule and sibling py_venv.   |  none |


<a id="py_venv"></a>

## py_venv

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_venv")

py_venv(<a href="#py_venv-freethreaded">freethreaded</a>, <a href="#py_venv-kwargs">**kwargs</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv-freethreaded"></a>freethreaded |  <p align="center"> - </p>   |  `None` |
| <a id="py_venv-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


<a id="py_venv_link"></a>

## py_venv_link

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_venv_link")

py_venv_link(<a href="#py_venv_link-name">name</a>, <a href="#py_venv_link-venv">venv</a>, <a href="#py_venv_link-link_name">link_name</a>, <a href="#py_venv_link-kwargs">**kwargs</a>)
</pre>

Emit a runnable target that materialises `venv` into the workspace.

`bazel run :<name>` creates a symlink in `$BUILD_WORKING_DIRECTORY`
(typically the workspace root) that points at the target's complete
runfiles tree. The command prints `venv`'s nested path below that link;
preserving the runfiles directory layout keeps the venv's relative paths
valid for Python and IDEs. This requires directory-based runfiles; a
manifest alone cannot expose a runfiles tree.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_venv_link-name"></a>name |  Runnable target name. `bazel run :<name>` materialises the runfiles symlink.   |  none |
| <a id="py_venv_link-venv"></a>venv |  Label of a `py_venv` target to link. Typically the `:<binary_name>.venv` target auto-emitted by `py_binary(expose_venv = True, ...)`, or a standalone `py_venv` shared across many binaries.   |  none |
| <a id="py_venv_link-link_name"></a>link_name |  Workspace-relative basename for the created runfiles symlink. Defaults to a safely-escaped version of the target's package + venv name.   |  `None` |
| <a id="py_venv_link-kwargs"></a>kwargs |  Forwarded to the underlying `py_binary`.   |  none |


<a id="py_wheel"></a>

## py_wheel

<pre>
load("@aspect_rules_py//py:defs.bzl", "py_wheel")

py_wheel(<a href="#py_wheel-name">name</a>, <a href="#py_wheel-twine">twine</a>, <a href="#py_wheel-twine_binary">twine_binary</a>, <a href="#py_wheel-publish_args">publish_args</a>, <a href="#py_wheel-kwargs">**kwargs</a>)
</pre>

Builds a Python Wheel.

Wheels are Python distribution format defined in https://www.python.org/dev/peps/pep-0427/.

This macro packages a set of targets into a single wheel.
It wraps the [py_wheel rule](#py_wheel_rule).

Currently only pure-python wheels are supported.

:::{versionchanged} 1.4.0
From now on, an empty `requires_file` is treated as if it were omitted, resulting in a valid
`METADATA` file.
:::

Examples:

```python
# Package some specific py_library targets, without their dependencies
py_wheel(
    name = "minimal_with_py_library",
    # Package data. We're building "example_minimal_library-0.0.1-py3-none-any.whl"
    distribution = "example_minimal_library",
    python_tag = "py3",
    version = "0.0.1",
    deps = [
        "//examples/wheel/lib:module_with_data",
        "//examples/wheel/lib:simple_module",
    ],
)

# Use py_package to collect all transitive dependencies of a target,
# selecting just the files within a specific python package.
py_package(
    name = "example_pkg",
    # Only include these Python packages.
    packages = ["examples.wheel"],
    deps = [":main"],
)

py_wheel(
    name = "minimal_with_py_package",
    # Package data. We're building "example_minimal_package-0.0.1-py3-none-any.whl"
    distribution = "example_minimal_package",
    python_tag = "py3",
    version = "0.0.1",
    deps = [":example_pkg"],
)
```

To publish the wheel to PyPI, the twine package is required and it is installed
by default on `bzlmod` setups. On legacy `WORKSPACE`, `rules_python`
doesn't provide `twine` itself
(see https://github.com/bazel-contrib/rules_python/issues/1016), but
you can install it with `pip_parse`, just like we do any other dependencies.

Once you've installed twine, you can pass its label to the `twine`
attribute of this macro, to get a "[name].publish" target.

Example:

```python
py_wheel(
    name = "my_wheel",
    twine = "@publish_deps//twine",
    ...
)
```

Now you can run a command like the following, which publishes to https://test.pypi.org/

```sh
% TWINE_USERNAME=__token__ TWINE_PASSWORD=pypi-*** \
    bazel run --stamp --embed_label=1.2.4 -- \
    //path/to:my_wheel.publish --repository testpypi
```


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_wheel-name"></a>name |  A unique name for this target.   |  none |
| <a id="py_wheel-twine"></a>twine |  A label of the external location of the py_library target for twine   |  `None` |
| <a id="py_wheel-twine_binary"></a>twine_binary |  A label of the external location of a binary target for twine.   |  `Label("@rules_python//tools/publish:twine")` |
| <a id="py_wheel-publish_args"></a>publish_args |  arguments passed to twine, e.g. ["--repository-url", "https://pypi.my.org/simple/"]. These are subject to make var expansion, as with the `args` attribute. Note that you can also pass additional args to the bazel run command as in the example above.   |  `[]` |
| <a id="py_wheel-kwargs"></a>kwargs |  other named parameters passed to the underlying [py_wheel rule](#py_wheel_rule)   |  none |


