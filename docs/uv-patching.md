# Patching Python Packages

The `uv.override_package()` tag class supports applying patches to Python packages resolved from a lockfile. This allows you to fix upstream packaging issues, remove unnecessary test/doc files, or modify package behavior without forking the upstream project.

## Overview

There are three kinds of overrides:

- **Full replacement** (`target`): Replace a package entirely with a custom Bazel target.
- **Pre-build patches** (`pre_build_patches`): Patch the extracted source distribution before building a wheel. Useful for fixing build scripts or source code.
- **Post-install patches** (`post_install_patches`): Patch the installed package tree after wheel unpacking. Useful for fixing installed library code.

Additionally, `extra_deps` and `extra_data` allow adding dependencies or data
files to the generated `py_library` target for a package.
`console_scripts` declares the complete script map for a wheel built from an
sdist so venv assembly can create wrappers during analysis.

## Prerequisites

The patching features require a `patch` binary (from diffutils) available on the host system. The extension automatically discovers it; no manual toolchain registration is needed.

## Examples

### Patching installed packages

The most common case is fixing an installed package. For example, many NVIDIA packages ship a conflicting `nvidia/__init__.py` that causes import errors when multiple NVIDIA packages are installed together:

```starlark
uv = use_extension("@aspect_rules_py//uv:extension.bzl", "uv")

uv.override_package(
    lock = "//:uv.lock",
    name = "nvidia-cublas-cu12",
    post_install_patches = ["//patches:nvidia-strip-init.patch"],
    post_install_patch_strip = 1,
)
```

Where `patches/nvidia-strip-init.patch` might look like:

```diff
--- a/install/lib/python3.12/site-packages/nvidia/__init__.py
+++ b/install/lib/python3.12/site-packages/nvidia/__init__.py
@@ -1,5 +1 @@
-# Some conflicting namespace init
-from nvidia._init import *
-__all__ = [...]
+# Stripped by aspect_rules_py override
```

The file remains in place, so `nvidia` stays a regular package. Post-install
patches may not remove package roots or change a package between regular and
namespace forms; use full replacement when the installed topology itself must
change.

### Applying the same patch to multiple packages

Use a Starlark list comprehension:

```starlark
[uv.override_package(
    lock = "//:uv.lock",
    name = pkg,
    post_install_patches = ["//patches:nvidia-strip-init.patch"],
    post_install_patch_strip = 1,
) for pkg in [
    "nvidia-cublas-cu12",
    "nvidia-cuda-runtime-cu12",
    "nvidia-cudnn-cu12",
    "nvidia-cufft-cu12",
    "nvidia-nccl-cu12",
]]
```

### Patching source distributions before build

If a package is built from source (sdist) and the build script needs fixing:

```starlark
uv.override_package(
    lock = "//:uv.lock",
    name = "legacy-package",
    pre_build_patches = ["//patches:legacy-fix-setup.patch"],
    pre_build_patch_strip = 1,
)
```

Pre-build patches are applied to the extracted source tree after archive extraction but before `python -m build` runs. This is useful for:

- Fixing `setup.py` or `pyproject.toml` issues
- Removing problematic native build dependencies
- Patching source code that affects the build output

### Adding extra dependencies or data

Some packages have implicit runtime dependencies that aren't declared in their metadata:

```starlark
uv.override_package(
    lock = "//:uv.lock",
    name = "some-package",
    extra_deps = [
        "//third_party:libfoo",
    ],
    extra_data = [
        "//config:some_package_defaults.ini",
    ],
)
```

### Reserving wheel build resources

Native sdist builds can be memory-hungry. Without a hint, Bazel assumes the
default per-action estimate (~1 CPU, 250 MB) and may schedule several heavy
builds at once, leading to OOM kills on the local machine. Set `resource_set`
to reserve more RAM (or CPU) for a package's wheel build so Bazel limits how
many run concurrently:

```starlark
uv.override_package(
    lock = "//:uv.lock",
    name = "native-package",
    resource_set = "mem_8g",
)
```

`resource_set` accepts bazel-lib's predefined values — the same vocabulary
`ts_project` uses: `"mem_512m"`, `"mem_1g"`, `"mem_2g"`, `"mem_4g"`,
`"mem_8g"`, `"mem_16g"`, `"mem_32g"`, `"cpu_2"`, `"cpu_4"`, or `"default"`
(reserve nothing extra). A memory request is rounded up to the named bucket.

`resource_set` only applies to packages built from an sdist. Setting it on a
package that resolves to a prebuilt wheel (no source build) fails the build
rather than silently dropping the reservation — force a source build with
`[tool.uv] no-binary-package` if you need the reservation to apply.

### Monitoring wheel build memory

Set `monitor_memory` to report the memory observed while building a wheel from
an sdist:

```starlark
uv.override_package(
    lock = "//:uv.lock",
    name = "native-package",
    monitor_memory = True,
)
```

On Linux, rules_py reports the first sample, each 256 MiB high-water crossing,
and the final peak. Reports are flushed as the build runs, so an earlier
high-water mark can remain in the action log when an OOM kills the build.

The measurement is a best-effort sum of `/proc` RSS for the build process and
its descendants. It can double-count shared pages and miss short-lived
processes. On other platforms it is reported as unavailable.

`monitor_memory` is diagnostic only. It neither limits memory nor reserves
scheduler capacity, and can be enabled independently from `resource_set`.

Monitoring runs only when the source-build target is selected. A package with
both an sdist and a compatible wheel produces no report when the wheel is
selected; use `[tool.uv] no-binary-package` to force the monitored source build.
A package with no sdist rejects the override.

A custom sdist configure tool that returns complete `build_file_content` owns
the wheel action itself. Such content must add its own monitoring; combining
that replacement with `monitor_memory` is rejected rather than silently
dropping the diagnostic.

### Full replacement

To replace a package entirely with a custom target (existing functionality):

```starlark
uv.override_package(
    lock = "//:uv.lock",
    name = "my-workspace-package",
    target = "//src/my_package:lib",
)
```

## Constraints

- Each `(lock, name, version)` triple may only have one `override_package` declaration. Duplicates are an error.
- `target` is mutually exclusive with all other modification attributes. Use `target` for full replacement OR the patch/modification attributes, not both.
- The `version` attribute is optional and defaults to whatever version the lockfile resolves.
- `console_scripts` applies only when the lock record has a source
  distribution. Prebuilt wheels use their inspected metadata.
- Pre-build patches only apply to packages that have a source distribution in the lockfile. If a package only has pre-built wheels, `pre_build_patches` has no effect.
- Post-install patches to prebuilt wheels must preserve every original path
  used for collision and regular-package merge planning, including its
  file-or-directory kind and package classification. Ordinary added paths are
  not enumerated by this validation and may not be visible to venv consumers.
  Source-built wheel topology is unavailable during analysis and remains
  unvalidated.

## Future work

Support for `srcs_exclude_glob` and `data_exclude_glob` (to exclude files like tests and docs from installed packages) is planned but not yet implemented. This requires extending the wheel unpack tool to accept exclusion patterns.
