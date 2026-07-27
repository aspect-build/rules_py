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
empty map suppresses all detected scripts. For a native
extension built from an sdist, `cc_deps` wires Bazel `cc_library` targets
(their headers and static archives) into the build.

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

### Linking native C/C++ dependencies

A package with a native extension often needs a C/C++ library: its headers to
compile against and its static archive to link. `cc_deps` wires a Bazel target
that provides `CcInfo` (a `cc_library`, `cc_import`, or similar) directly into
the sdist build: the dependency's transitive headers, include paths, defines,
and Apple framework search paths become compile flags (appended to `CPPFLAGS`),
and its static archives are placed in the linker's post-object slot. The
transitive closure and link order come from `CcInfo`, so you name only the
top-level target.

`cc_deps` is the declarative counterpart to the `env` / `toolchains` escape hatch
(see [the constraints below](#constraints)): reach for `cc_deps` to _declare_ the
native dependency, and keep `env` for _tweaking_ the build: package-specific
defines, exotic linker flags, or anything `cc_deps` cannot model. The two
compose; `cc_deps` flags are appended after any you set in `env`.

For example, building a package's native extension against an in-repo C
library. Before, with the raw `env` / `toolchains` escape hatch, the include
and archive paths are anchored by hand with `$(EXECROOT)` and fed through
make-variables a toolchain exports:

```starlark
uv.override_package(
    name = "native-package",
    toolchains = ["//third_party/mylib:make_vars"],  # exports $(MYLIB_INC), $(MYLIB_LIB_A)
    env = {
        "CPPFLAGS": "-I$(EXECROOT)/$(MYLIB_INC)",
        "LDFLAGS": "$(EXECROOT)/$(MYLIB_LIB_A)",
    },
)
```

After, with `cc_deps`, the include path, the archive, and their transitive
closure are read from the target's `CcInfo`, and no path anchoring is needed:

```starlark
uv.override_package(
    name = "native-package",
    cc_deps = ["//third_party/mylib"],  # a cc_library / cc_import
)
```

The dependency target must be visible to the generated build repository, so mark
it `//visibility:public` (or grant that repository's package visibility). See the
[constraints below](#constraints) for the supported-library and setuptools
requirements.

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
  Removing the complete `.dist-info` directory, `METADATA`, or `RECORD` is
  unsupported.
- `pre_build_patches`, `toolchains`, `env`, `cc_deps`, `monitor_memory`, and
  non-default `resource_set` values require a source distribution. An override
  that applies them to a wheel-only lock record is rejected.
- Generated pure-Python builds reject `toolchains`, `env`, and `cc_deps`; those
  attributes augment the native build toolchain, environment, and link inputs.
- Native build `env` values can use `$(EXECROOT)/` to anchor paths supplied by
  a toolchain, for example `CPPFLAGS = "-I$(EXECROOT)/$(DEP_INC)"` and
  `LDFLAGS = "$(EXECROOT)/$(DEP_LIB_A)"`. The anchor remains valid after the
  PEP 517 backend changes into the unpacked source tree.
- Native builds select the configured C++ compiler, archiver, linker, and strip
  tools by default. Explicit `CC`, `CXX`, `AR`, `LD`, and `STRIP` values in
  `env` override those selections.
- `cc_deps` applies only to sdists built by the setuptools backend. A package
  that declares any other `[build-system].build-backend` is rejected when the
  wheel is built (`cc_deps is only supported with the setuptools build backend`)
  rather than having its inputs silently dropped.
- The build environment's setuptools must be `>= 65.4.0`, the release that
  added `DIST_EXTRA_CONFIG`, the channel `cc_deps` routes the link inputs
  through. An older or missing setuptools fails the build with
  `cc_deps requires setuptools >= 65.4.0`; bump it in the lock that supplies your
  build dependencies (`uv.lock` / `default_build_dependencies`).
- Only static (or PIC-static) archives are linked. A dependency that provides
  only a shared/dynamic library fails at analysis time, as does an `alwayslink`
  (whole-archive) library; neither is supported.
- The linked archives must contain position-independent (PIC) objects, because
  they are folded into the extension's shared object. A toolchain that emits
  non-PIC objects into its static archives (some GCC configurations) fails the
  final link with relocation errors such as `relocation R_X86_64_32 against ...
can not be used when making a shared object; recompile with -fPIC`. Remedies:
  use a toolchain that compiles PIC objects (the default on macOS, and clang/LLVM
  on Linux), build with `--force_pic`, or add `copts = ["-fPIC"]` to the
  `cc_library`.
- Each `cc_deps` label is referenced from the generated external build
  repository, so the target must be visible to it: use `//visibility:public` or
  grant that repository's package visibility.
- Link flags that reference a file the dependency declares via
  `additional_linker_inputs` (for example a `-Wl,--version-script,...` linker
  script) are path-anchored automatically so they survive the backend changing
  directory. A relative path written directly into `linkopts` without declaring
  the file there is not anchored and will not resolve after the change.
- `cc_deps` flattens a dependency's link inputs into setuptools' two link slots:
  full-path static archives go to the post-object `[build_ext] link_objects`
  slot in topological order; bare `-l<name>` entries go to the post-object
  `[build_ext] libraries` slot preserving their relative order; and every other
  link flag is appended to `LDFLAGS` ahead of the objects. Because the archives
  and `-l` entries land in separate slots, the order between an `-l<name>` entry
  and a non-`-l` flag cannot be preserved, so only flags whose effect does not
  depend on that relative order are passed through. `cc_deps` accepts a fixed set
  of link-flag shapes: `-L<dir>` search paths; `-pthread`; and `-Wl,` tokens
  built from these directives: the rpath family (`-rpath`, `-rpath=`, and
  `-rpath-link`), `--version-script` (comma and `=` argument forms), `-z` with
  one of the reviewed keywords `relro`, `now`, `noexecstack`, or `origin` (each
  a global link mode; the wider `-z` namespace includes position-sensitive
  keywords, so others are rejected), and `--enable-new-dtags`. A comma-joined
  `-Wl,` token is validated directive by directive, so an accepted leading
  directive cannot smuggle a rejected one behind it (`-Wl,-rpath,/x,--as-needed`
  fails, naming `--as-needed`), while benign compounds such as
  `-Wl,-z,relro,-z,now` and `-Wl,-rpath,$ORIGIN,--enable-new-dtags` pass. Any
  other link flag, including grouping and linker-state toggles such as
  `--start-group`/`--end-group` or `--as-needed`, is rejected at analysis time
  rather than silently reordered. The split `-L <dir>` form is rejected too;
  write the glued `-L<dir>`. Apple `-framework` linking is not supported in v1:
  ld64 resolves frameworks in command-line order alongside `-l` entries, so the
  two-slot split cannot hold one; set the framework in the override's `env`
  `LDFLAGS` or patch it in with `pre_build_patches`. Three escape hatches cover
  what the allowlist does not: to resolve an archive cycle that would otherwise
  need `--start-group`, repeat the library name (for example `-la -lb -la`),
  since `-l` order is preserved within the libraries slot; to apply a global
  toggle such as `--as-needed` to the whole link, set it in the override's
  `env` `LDFLAGS`, which lands ahead of the objects; and for anything else,
  patch it in with `pre_build_patches` on the sdist. The accepted set can be
  extended upstream on request.
- Post-install patches to prebuilt wheels must preserve every retained original
  path used for collision and regular-package merge planning, including its
  file-or-directory kind and package classification. Ordinary added paths are
  not enumerated by this validation and may not be visible to venv consumers.
  Source-built wheel topology is unavailable during analysis and remains
  unvalidated.
- Gazelle indexes the raw wheel as an unfiltered superset. Preserving top-level
  import roots keeps ordinary mappings valid, but precise mappings for shared
  namespaces or excluded submodules can remain in the generated manifest.
