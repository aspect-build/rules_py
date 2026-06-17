# `aspect_rules_py//uv`

`aspect_rules_py` provides an alternative to the venerable `rules_python`
`pip.parse` implementation, which leverages the
[uv](https://github.com/astral-sh/uv) lockfiles instead of `requirements.txt` to
configure PyPi dependencies.

Our uv is a drop-in replacement for basic `pip.parse` usage, but provides a
number of additional features.

**Dependency groups** - Uv supports [PEP 735 dependency
groups](https://peps.python.org/pep-0735/): each `[dependency-groups]` entry
in your `pyproject.toml` registers as a named group your build can switch
between. Flip the `--@<hub>//dep_group=<name>` flag, or set
`dep_group="<name>"` on a `py_binary` / `py_test` target.

**Effortless Crossbuilds** - Uv delays building and installing packages until
the build is configured. This allows uv to build your requirements in crossbuild
configurations, such as going from a Darwin macbook to a Linux container image
using only the normal Bazel `platforms` machinery.

**Correct source builds** - Because uv performs package source builds as a
normal part of your build, it's able to use hermetic or even source built Python
toolchains in addition to Bazel-defined dependencies and C compilers. Future
support for sysroots is planned. Due to its phasing, `pip.parse` is stuck doing
all this non-hermetically.

**Editable requirements** - Uv provides an `uv.override_requirement()` tag which
allows locked requirements to be replaced with 1stparty Bazel `py_library`
targets. This lets you substitute in vendored code, use custom build actions to
produce library files, or just iterate on patches easily.

**Lightning fast configuration** - The only work uv has to do at repository time
is reading toml files. Downloads and builds all happen lazily.

**Platform independence** - No more need to separate `requirements_mac`,
`requirements_linux` and `requirements_windows` or your build exploding because
you `query`-ed a platform incompatible requirement. Uv can always configure all
of your requirements, and all hub labels are always available.

**Mirror friendly** - Relying on uv's locked dependency graph allows the
extension to only use the Bazel downloader, ensuring compatibility with private
or mirrored wheels.

**Automatic cycle support** - Requirement dependency cycles such as those in
Airflow are automatically detected and resolved. User intervention is no longer
required.

## Quickstart

The first step is to generate a `uv.lock` file. In contrast to a conventional
`requirements.txt`, the uv lockfile contains both the dependency graph between
requirements and detailed information about the wheels and sdists.

The `uv_bin.toolchain()` tag below registers a Bazel-managed `uv`, so you can
invoke it via `bazel run @uv -- …` without installing `uv` globally. From a
workspace that already has a `pyproject.toml`:

```shell
bazel run @uv -- lock
```

If you're migrating from `requirements.txt`, use uv's own import flow to
create a `pyproject.toml` and seed it:

```shell
bazel run @uv -- init --no-workspace
bazel run @uv -- add -r requirements_lock.txt
```

We can now use the lockfile to configure our build.

This configuration declares a dependency hub, creates two dependency groups
(`default` and `vendored_say`), and shows how to use `uv.override_package`
to swap a locked requirement (`cowsay`) for a local one.

```starlark
# MODULE.bazel
bazel_dep(name = "aspect_rules_py", version = "1.6.7") # Or later

uv_bin = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv_bin")
uv_bin.toolchain(version = "0.11.6")
use_repo(uv_bin, "uv")

uv = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv")
uv.declare_hub(
    hub_name = "pypi",      # Or whatever you wish
)
uv.project(
    hub_name = "pypi",      # Must be a declared hub
    pyproject = "//:pyproject.toml",
    lock = "//:uv.lock",
)

uv.override_package(
    lock = "//:uv.lock",
    name = "cowsay",
    # version = "",    Optional but may be required for disambiguation
    target = "//third_party/py/cowsay:cowsay",
)

# This one hub now has two configurations ("dependency groups") available
use_repo(uv, "pypi")

register_toolchains("@uv//:all")
```

We can configure a default dependency group by setting the `dep_group` flag on our hub as part of the `.bazelrc`.
Each `[dependency-group]` of the `pyproject.toml` is registered as a named dependency group.
If no dependency groups are listed, an implicit default group with the name of the project itself is created.

```
# .bazelrc
common --@pypi//dep_group=dummy
```

Individual targets can request different dependency groups if multiple dependency groups are configured.

```
# BUILD.bazel
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(
   name = "say",
   srcs = ["__main__.py_"],
   deps = ["@pypi//cowsay"],
)

py_binary(
   name = "say_vendored",
   srcs = ["__main__.py_"],
   deps = ["@pypi//cowsay"],
   dep_group = "vendored_say",    # Change the default dep_group choice
)
```

## The `uv` toolchain

`uv_bin.toolchain()` fetches the UV binary for the required platform(s) and
publishes `@uv`:

- `@uv//:uv` — host-platform alias for ad-hoc use (`bazel run @uv`,
  `genrule(tools=…)`, `sh_binary(data=…)`).
- `@uv//:all` — per-platform toolchains for `register_toolchains`.

Optional attributes:

- `name` — hub repo name; defaults to `"uv"` (i.e. `@uv`). Set to a distinct
  value to publish an additional hub (e.g. `@uv_legacy//:uv`) alongside the
  default.
- `version` — defaults to the latest version known to aspect_rules_py.
  Unknown versions are still fetchable but non-reproducible unless paired
  with `sha256s`.
- `urls` — mirror templates with `{version}`, `{platform}`, `{ext}`
  placeholders; tried in order. Defaults to the upstream GitHub release URL.
- `sha256s` — map of platform triple to SHA256. Overrides or supplies the
  hashes baked into aspect_rules_py. Entries are optional per-platform; a
  platform with an empty-string hash fetches without integrity verification
  and the download is marked non-reproducible (its bytes may vary across
  users).

## Relationship to interpreter provisioning

Unlike `rules_python`, there is no coupling between `uv.project()` and Python
interpreter provisioning. The uv extension only reads lockfiles and generates
build targets — it does not download or configure Python interpreters.

At build time, Bazel's normal toolchain resolution selects an interpreter. You
can provide one via `aspect_rules_py`'s own `python_interpreters` extension
(see [interpreter.md](interpreter.md)), via `rules_python`'s
`python.toolchain()`, or any other mechanism that registers a
`@bazel_tools//tools/python:toolchain_type` toolchain. As long as an
appropriate Python toolchain is registered for the target platform, uv targets
will build correctly regardless of how that toolchain was provisioned.

## Example: Doing crossbuilds

The uv machinery honors the `@platforms//cpu` and `@platforms//os` constraint
settings, and will attempt to provide installations of libraries matching the
active constraint set.

In order to cope with various libcs and libc compatibility ranges, uv also has
two internal config setting flags

```
--@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc
--@aspect_rules_py//uv/private/constraints/platform:platform_version=2.39
```

The `platform_libc` flag must be the name of a libc (eg. glibc, musl, libsystem,
...) and the `platform_version` flag must be the `major.minor` version of that
libc on the targeted system. This allows for users to specify that they're
crossbuilding from `linux-glibc@2.40` to `linux-musl@1.2` and such.

Crossbuilds can be accomplished simply by setting the `--platform` flag, or
using platform transitions.

```
load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer")

platform(
    name = "arm64_linux",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
    # These flags must be reset to values appropriate for the target.
    # Their default values are appropriate to the host.
    flags = [
        "--@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc",
        "--@aspect_rules_py//uv/private/constraints/platform:platform_version=2.39",
    ],
)

py_binary(
    name = "app_bin",
    srcs = ["__main__.py"],
    main = "__main__.py",
    python_version = "3.12",
    dep_group = "psql",
    deps = [
        "@pypi//psycopg2_binary",
    ],
)

# OCI layers containing the binary
py_image_layer(
    name = "app_layers",
    binary = ":app_bin",
)

# The layers reconfigured according to the specified platform
platform_transition_filegroup(
    name = "arm64_layers",
    srcs = [":app_layers"],
    target_platform = ":arm64_linux",
)
```

## Example: Constraining library compatibility

By default uv hubs let you write `py_library` and other targets which are
compatible with _any_ dependency group providing all the needed requirements.

But sometimes you want a library to be incompatible with a dependency group;
either because it depends on packages at versions below what are available in
that dependency group or as part of an internal migration or for some other reason.

As a facility each hub's `@<hub>//:defs.bzl` provides a pair of helper macros
for generating appropriate `target_compatible_with` logics. These helpers return
case dicts which may either be manipulated or `select()`ed on.

```
load("@pypi//:defs.bzl", "compatible_with", "incompatible_with")

py_library(
  name = "requires_prod",
  srcs = ["foo.py"],
  deps = ["@pypi//cowsay"],
  # Allowlist
  target_compatible_with = select(compatible_with(["prod"])),
)

py_library(
  name = "not_in_prod",
  srcs = ["foo.py"],
  deps = ["@pypi//cowsay"],
  # Allowlist
  target_compatible_with = select(incompatible_with(["prod"])),
)
```

## A mental model

```
@pypi                                     # Your UV built hub repository
@pypi//requests:requests                  # The library for a requirement
@pypi//jinja2-cli/entrypoints:jinja2-cli  # A requirement's declared entrypoint
```

This central hub wraps "spoke" internal dependency group repos. For instance if you have two
dependency groups "a" and "b", then each hub target for a requirement is a `select()` alias
over the dependency group targets in which that requirement is defined.

Hub requirement targets are _incompatible_ with dependency group configurations in which the
requirement in question is not defined.

Each dependency group requirement is backed by a `whl_install` rule which chooses among
prebuilt wheels listed in the lockfile to produce the equivalent of a
`py_library`.

An sdist (if available) will be built into a wheel for installation if no wheels
are available, or no wheels matching the target configuration are found. Sdist
builds occur using the configured Python and Cc toolchains.

A wheel built from an sdist does not exist until execution, after Bazel has
finished analysis. When its final topology is independent of the target
configuration, declare that package-version metadata once so every matching
lock can expose console scripts and merge package roots during analysis:

```starlark
uv.built_wheel_metadata(
    name = "cowsay",
    version = "6.0",
    top_levels = [
        "cowsay",
        "cowsay-6.0.dist-info",
    ],
    directory_top_levels = [
        "cowsay",
        "cowsay-6.0.dist-info",
    ],
    console_scripts = [
        "cowsay=cowsay.__main__:cli",
    ],
)
```

`top_levels` must list every immediate entry that the wheel installs into
`site-packages`; `directory_top_levels` is the complete directory subset. The
unpack action compares the declaration with each built wheel and fails on
drift. Every source-buildable match must refer to the same source hash, URL, or
Git source; the module extension rejects conflicting sources. Lock-specific
pre-build patches must preserve the declared topology.

Do not declare metadata when topology can vary by target configuration, such
as a native extension whose filename contains an ABI-specific suffix. The
package then uses the source-wheel fallback instead of exposing incomplete
analysis-time metadata.

## Best practices

**Consolidate your hubs**. In `rules_python`, environments with multiple depsets
needed to make multiple `pip.parse()` calls each of which created a hub. This
created the problem of transitive depset inconsistency (this target uses deps
from this hub but depends on a library that uses deps from elsewhere).

By using single hub throughout your repository and leaning on dependency group configuration
to choose the right one at the right point in time, your dependency management
gets a lot easier and your builds become internally consistent.

**Only use one hub**. The hub name is configurable in order to accommodate
whatever your existing `pip.parse` may be called, but there's no reason to use
more than one hub within a single repository. Each dependency set should be
registered as a separate dependency group within the same hub.

## Gazelle integration

If you use [Gazelle](https://github.com/bazelbuild/bazel-gazelle) with the
[aspect-gazelle](https://github.com/aspect-build/aspect-gazelle) Python
extension, you need a `gazelle_python.yaml` manifest that maps Python import
names to their PyPI package names. The `gazelle_python_manifest` rule generates
this file from your locked wheels.

```starlark
# BUILD.bazel (typically at the workspace root)
load("@aspect_rules_py//uv:defs.bzl", "gazelle_python_manifest")

gazelle_python_manifest(
    name = "gazelle_python_manifest",
    hub = "pypi",
    venvs = ["default"],
)
```

**Parameters:**

- `hub` — The name of your uv hub (must match `uv.declare_hub(hub_name = ...)`).
- `venvs` — List of dependency group names whose wheels should be indexed. Module mappings
  from all listed dependency groups are merged into a single manifest.

This creates two targets:

- `:gazelle_python_manifest` — builds the manifest YAML
- `:gazelle_python_manifest.update` — copies the built manifest into your source tree

To generate or refresh the manifest:

```shell
bazel run //:gazelle_python_manifest.update
```

This writes `gazelle_python.yaml` next to the BUILD file. Commit it to your
repository so that Gazelle can resolve Python imports without rebuilding the
manifest on every invocation.

If you have multiple dependency groups with different dependency sets, list them all to
produce a complete mapping:

```starlark
gazelle_python_manifest(
    name = "gazelle_python_manifest",
    hub = "pypi",
    venvs = ["web", "ml", "cli"],
)
```

## Troubleshooting

### Verbose logging for uv repository rules

To diagnose issues with source distribution (sdist) builds or git archive fetching,
set the `RULES_PY_UV_VERBOSE` environment variable to any non-empty value:

```bash
bazel build --repo_env=RULES_PY_UV_VERBOSE=1 //...
```

You can also set it in your `.bazelrc` to apply to all builds:

```
# .bazelrc
common --repo_env=RULES_PY_UV_VERBOSE=1
```

When enabled, `rules_py` prints additional diagnostic information during
repository rule execution, including:

- **Sdist inspection failures** — output from the sdist configure tool when it fails.
- **Missing archives** — warnings when an archive path cannot be resolved from a source label.
- **Native source detection** — confirmation when native (non-Python) sources are detected in an sdist.
- **Pure-Python fallback** — warnings when an sdist cannot be inspected and a pure-Python build is assumed.
- **Git archive commands** — the exact `git` command executed and its stdout/stderr.
- **Package version overrides** — confirmation when a package version is overridden with a local target.

## Differences and Gotchas

**Lock your build tools**. In order to perform sdist builds and support
libraries which are packaged only as sdists (which is more common than you'd
think) uv needs a Python build tool to use. Uv currently uses `setuptools` and
`build`, both of which must be installed in your lock solution. You may
encounter configuration errors if these tools would be required and are not
available.

**No default dependency group?** In order to implement the `dep_group=` transition on `py_binary`
et. all, the `dep_group` flag has to be statically known. This means we get one global
"current dependency group" flag, no matter how many hubs you have.

It only really makes sense to use the `--@pypi//dep_group=default` flag as part of
your `.bazelrc`, because then the scope of where that default is applied is well
bounded to your repository with your hub.

We could allow the `_main` repository to set a default dependency group name, but the
semantics are weird if the `_main` repository defines more than one hub. Which
is poor practice but possible. So rather than have weird behavior we don't
support this.

**What's with annotations?** The `uv.lock` format is great, but it's missing
some key information. Such as what requirements apply when performing sdist
builds. Annotations are the current workaround for how to associate such
required but nonstandardized and missing dependency data with requirements.

**Why aren't entrypoints automatically created?** `pip.parse` performs library
installs at repository time, which allows it to inspect the installed files and
detect entrypoints. Because uv does installs using normal build actions it has
no way to see what binaries may be created or what `.dist-info/entry_points.txt`
records exist.

If you need a given entrypoint as a Bazel target, it needs to be manually
declared. In most cases of normal entrypoints this is quite easy. Tools like
`ruff` which distribute binaries as "wheels" are tricky and not yet supported.

## Acknowledgements

- Jeremy Volkman's `rules_pycross` is in a direct precursor and inspiration for
  this tool. They use the same strategy, uv is just able to leverage an off the
  shelf lockfile format which postdates Jeremy's efforts.

- Richard Levasseur and Ignas Anikevicius of `rules_python` have been great
  collaborators and good sports in my treating the `rules_python` authors
  meeting as the bazel-python-sig. Ignas in particular created the marker
  evaluation code which makes uv's conditional dependency activation possible,
  and Richard provided the example for programmable constraints with flags.

This work was made possible by support from Physical Intelligence, the RAI
Institute and others to whom we're grateful.
