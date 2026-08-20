# Patching Python Packages

The `uv.override_package()` tag class supports applying patches to Python packages resolved from a lockfile. This allows you to fix upstream packaging issues, remove unnecessary test/doc files, or modify package behavior without forking the upstream project.

## Overview

There are three kinds of overrides:

- **Full replacement** (`target`): Replace a package entirely with a custom Bazel target.
- **Pre-build patches** (`pre_build_patches`): Patch the extracted source distribution before building a wheel. Useful for fixing build scripts or source code.
- **Post-install patches** (`post_install_patches`): Patch the installed package tree after wheel unpacking. Useful for fixing installed library code.

Additionally, `extra_deps` and `extra_data` allow adding dependencies or data files to the generated `py_library` target for a package.

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

### Providing native build inputs to sdist builds

Some sdists compile C/C++ extensions against headers and libraries that are
not part of the CC toolchain sysroot. `native_inputs` threads Bazel targets
into the hermetic `pep517_native_whl` build action:

```starlark
uv.override_package(
    lock = "//:uv.lock",
    name = "some-native-package",
    native_inputs = [
        "//third_party/zlib:zlib",
    ],
)
```

Semantics per target:

- **Targets with `CcInfo`** (e.g. `cc_library`): the compilation context's
  headers become action inputs and its include directories and defines are
  passed to the compiler (`-I`/`-iquote`/`-isystem`/`-D` via
  `CPPFLAGS`/`CFLAGS`/`CXXFLAGS`). Static libraries from the linking context
  are force-loaded into the extension link (`LDFLAGS`); libraries that expose
  only object files have those objects linked directly.
- **Targets without `CcInfo`** (e.g. `filegroup`): files are staged into the
  build sandbox and their absolute paths exposed via the
  `PY_NATIVE_INPUT_PATHS` environment variable (path-separator delimited) for
  the build backend (`setup.py` etc.) to consume explicitly.

Only the **compile-time** case is supported: headers plus static libraries.
A target whose linking context offers only shared libraries is rejected at
analysis time — an installed wheel has no rpath into `bazel-out`, so a
dynamically linked extension would fail at import time with unresolved
symbols. Build the dependency as a static archive instead (a plain
`cc_library` always provides one).

`native_inputs` only applies to packages built from source. Declaring it for
a package that never gets a source build (no sdist in the lockfile, or an
anyarch wheel satisfies all installs) or for an sdist confidently classified
as pure-Python is an error. When the classification is uncertain (sdist
inspection unavailable) or `pre_build_patches` could introduce native
sources, `native_inputs` acts as an explicit signal and the native build
path is used.

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
- Pre-build patches only apply to packages that have a source distribution in the lockfile. If a package only has pre-built wheels, `pre_build_patches` has no effect.

## Future work

Support for `srcs_exclude_glob` and `data_exclude_glob` (to exclude files like tests and docs from installed packages) is planned but not yet implemented. This requires extending the wheel unpack tool to accept exclusion patterns.
