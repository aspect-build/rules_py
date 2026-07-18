# Patching Python Packages

The `uv.override_package()` tag class supports applying patches to Python packages resolved from a lockfile. This allows you to fix upstream packaging issues, remove unnecessary test/doc files, or modify package behavior without forking the upstream project.

## Overview

There are three kinds of overrides:

- **Full replacement** (`target`): Replace a package entirely with a custom Bazel target.
- **Pre-build patches** (`pre_build_patches`): Patch the extracted source distribution before building a wheel. Useful for fixing build scripts or source code.
- **Post-install patches** (`post_install_patches`): Patch the installed package tree after wheel unpacking. Useful for fixing installed library code.

Additionally, `extra_deps` and `extra_data` allow adding dependencies or data
files to the generated `py_library` target for a package.
`console_scripts` overrides the complete script map for a wheel built from an
sdist when its egg-info metadata is absent or unsuitable. An explicit
empty map suppresses all detected scripts.

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
patches may not remove retained package roots or change retained packages
between regular and namespace forms; exclude the affected paths or use full
replacement when the installed topology itself must change.

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

### Applying a patch across all locks

Omit `lock` to apply a modification wherever a package is present in the
`uv.project()` locks declared by the same module:

```starlark
uv.override_package(
    name = "nvidia-cublas-cu12",
    post_install_patches = ["//patches:nvidia-strip-init.patch"],
    post_install_patch_strip = 1,
)
```

An explicit `version` limits the modification to locks containing that
version. Locks without the package or selected version are skipped, but an
override that matches no locks is an error.

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
- An explicit `lock` must identify a `uv.project()` declared by the same
  module. Omitting it applies modifications across all of that module's locks.
- An unscoped override supports modifications only; full `target` replacement
  requires an explicit `lock`.
- `target` is mutually exclusive with all other modification attributes. Use `target` for full replacement OR the patch/modification attributes, not both.
- The `version` attribute is optional and defaults to whatever version the lockfile resolves.
- `console_scripts` applies only when the lock record has a source
  distribution. Prebuilt wheels use their inspected metadata.
- An explicit `version` on a lock-scoped override must match a record for that
  package in the lockfile. Without `lock`, it must match at least one lock.
- Modification attributes cannot apply to virtual packages or the project's
  editable workspace package because neither produces an installed wheel.
- `pre_build_patch_strip` requires `pre_build_patches`, and
  `post_install_patch_strip` requires `post_install_patches`.
- `exclude_glob` removes site-packages-relative paths after installation and
  patching. `*` matches within one path segment, and `**` matches zero or more
  path segments. Matching a directory removes its subtree. Exclusions must
  preserve every top-level import root; for example, `numpy/**/tests/**`
  removes NumPy's bundled tests without retaining their compiled bytecode.
  Removing the complete `.dist-info` directory or its `RECORD` is unsupported.
- `pre_build_patches`, `toolchains`, `env`, `monitor_memory`, and non-default
  `resource_set` values require a source distribution. An override that applies
  them to a wheel-only lock record is rejected.
- A configure tool that returns complete `build_file_content` receives
  `pre_build_patches` and `pre_build_patch_strip` in its context and owns
  applying them. `toolchains`, `env`, `monitor_memory`, and non-default
  `resource_set` values are rejected because the configure context cannot
  convey them.
- Generated pure-Python builds reject `toolchains` and `env`; those attributes
  augment the native build toolchain and environment.
- Native build `env` values can use `$(EXECROOT)/` to anchor paths supplied by
  a toolchain, for example `CPPFLAGS = "-I$(EXECROOT)/$(DEP_INC)"` and
  `LDFLAGS = "$(EXECROOT)/$(DEP_LIB_A)"`. The anchor remains valid after the
  PEP 517 backend changes into the unpacked source tree.
- Native builds select the configured C++ compiler, archiver, linker, and strip
  tools by default. Explicit `CC`, `CXX`, `AR`, `LD`, and `STRIP` values in
  `env` override those selections.
- Post-install patches to prebuilt wheels must preserve every retained original
  path used for collision and regular-package merge planning, including its
  file-or-directory kind and package classification. Ordinary added paths are
  not enumerated by this validation and may not be visible to venv consumers.
  Source-built wheel topology is unavailable during analysis and remains
  unvalidated.
- Gazelle indexes the raw wheel as an unfiltered superset. Preserving top-level
  import roots keeps ordinary mappings valid, but precise mappings for shared
  namespaces or excluded submodules can remain in the generated manifest.
