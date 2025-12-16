# (experimental) `aspect_rules_py//uv`

`aspect_rules_py` provides an alternative to the venerable `rules_python`
`pip.parse` implementation, which leverages the
[uv](https://github.com/astral-sh/uv) lockfiles instead of `requirements.txt` to
configure PyPi dependencies.

Our uv is a drop-in replacement for basic `pip.parse` usage, but provides a
number of additional features.

**Configurable dependencies** - Uv allows for multiple lockfile states (called
venvs) to be registered into a single hub. Your build can be configured to
choose between registered venvs. It's as simple as flipping the
`--@<hub>//venv=<venv name>` flag. Binaries can also set the `venv=<venv name>`
attribute.

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

The first step is to generate a `uv.lock` file.

In contrast to a conventional `requirements.txt`, the uv lockfile contains both
the dependency graph between requirements, and detailed information about the
wheels and sdists for the requested requirements.

Assuming you haven't already adopted the `pyproject.toml` dependency manifest,
you can `uv add` your requirements lock to a dummy project and create a uv
lockfile.

```shell
d=$(mktemp -d)
cat <<'EOF' > $d/pyproject.toml
[project]
name = "dummy"
version = "0.0.0"
requires-python = ">= 3.9"
dependencies = []
EOF
cp requirements_lock.txt $d/
(
  cd $d
  uv add -r requirements_lock.txt
  uv lock
)
cp $d/uv.lock .
rm -r $d
```

We can now use the lockfile to configure our build.

This configuration declares a dependency hub, creates two virtual environments
(`default` and `vendored_say`), and shows how to use `uv.override_requirement`
to swap a locked requirement (`cowsay`) for a local one.

```starlark
# MODULE.bazel
bazel_dep(name = "aspect_rules_py", version = "1.6.7") # Or later
uv = use_extension("//uv/unstable:extension.bzl", "uv")
uv.declare_hub(
    hub_name = "pypi",      # Or whatever you wish
)
uv.declare_venv(
    hub_name = "pypi",      # Must be a declared hub
    venv_name = "default",  # Or whatever you wish
)
uv.lockfile(
    hub_name = "pypi",      # Must be a declared hub
    venv_name = "default",  # Must be a declared venv
    src = "//:uv.lock",
)

uv.declare_venv(
    hub_name = "pypi",
    venv_name = "vendored_say",
)
uv.lockfile(
    hub_name = "pypi",
    venv_name = "vendored_say",
    src = "//:uv.lock",
)
uv.override_requirement(
    hub_name = "pypi",
    venv_name = "vendored_say",
    requirement = "cowsay",
    target = "//third_party/py/cowsay:cowsay",
)

# This one hub now has two configurations ("venvs") available
use repository(uv, "pypi")
```

We can configure a default virtualenv by setting the venv configuration flag on our hub as part of the `.bazelrc`.

```
# .bazelrc
common --@pypi//venv=default
```

Individual targets can request different venvs if multiple venvs are configured.

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
   venv = "vendored_say",    # Change the default venv choice
)
```

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
load("@aspect_rules_py//py/unstable:defs.bzl", "py_venv_binary")
load("@aspect_rules_py//py:defs.bzl", "py_image_layer")
load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")

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

py_venv_binary(
    name = "app_bin",
    srcs = ["__main__.py"],
    main = "__main__.py",
    python_version = "3.12",
    venv = "psql",
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
compatible with _any_ virtualenv configuration providing all the needed
requirements.

But sometimes you want a library to be incompatible with a virtualenv state;
either because it depends on packages at versions below what are available in
that virtualenv or as part of an internal migration or for some other reason.

As a facility each hub's `@<hub>//:defs.bzl` provides a pair of helper macros
for generating appropriate `target_compatible_with` logics. These helpers return
case dicts which may either be manipulated or `select()`ed on.

```
load("@pypi//:defs.bzl", "compatible_with", "incompatible_with")

py_library(
  name = "requires_venv_a",
  srcs = ["foo.py"],
  deps = ["@pypi//cowsay"],
  # Allowlist
  target_compatible_with = select(compatible_with(["venv-a"])),
)

py_library(
  name = "deny_venv_a",
  srcs = ["foo.py"],
  deps = ["@pypi//cowsay"],
  # Allowlist
  target_compatible_with = select(incompatible_with(["venv-a"])),
)
```

## A mental model

```
@pypi                                     # Your UV built hub repository
@pypi//requests:requests                  # The library for a requirement
@pypi//requests:whl                       # The whl implementing a requirement
@pypi//requests:whl                       # The whl implementing a requirement
@pypi//jinja2-cli/entrypoints:jinja2-cli  # A requirement's declared entrypoint
```

This central hub wraps "spoke" internal venv repos. For instance if you have two
venvs "a" and "b", then each hub target for a requirement is a `select()` alias
over the venv targets in which that requirement is defined.

Hub requirement targets are _incompatible_ with venv configurations in which the
requirement in question is not defined.

Each venv requirement is backed by a `whl_install` rule which chooses among
prebuilt wheels listed in the lockfile to produce the equivalent of a
`py_library`.

An sdist (if available) will be built into a wheel for installation if no wheels
are available, or no wheels matching the target configuration are found. Sdist
builds occur using the configured Python and Cc toolchains.

## Best practices

**Consolidate your hubs**. In `rules_python`, environments with multiple depsets
needed to make multiple `pip.parse()` calls each of which created a hub. This
created the problem of transitive depset inconsistency (this target uses deps
from this hub but depends on a library that uses deps from elsewhere).

By using single hub throughout your repository and leaning on venv configuration
to choose the right one at the right point in time, your dependency management
gets a lot easier and your builds become internally consistent.

**Only use one hub**. The hub name is configurable in order to accommodate
whatever your existing `pip.parse` may be called, but there's no reason to use
more than one hub within a single repository. Each dependency set should be
registered as a separate venv within the same hub.

## Differences and Gotchas

**Lock your build tools**. In order to perform sdist builds and support
libraries which are packaged only as sdists (which is more common than you'd
think) uv needs a Python build tool to use. Uv currently uses `setuptools` and
`build`, both of which must be installed in your lock solution. You may
encounter configuration errors if these tools would be required and are not
available.

**No default venv?** In order to implement the `venv=` transition on `py_binary`
et. all, the venv flag has to be statically known. This means we get one global
"current venv" flag, no matter how many hubs you have.

It only really makes sense to use the `--@pypi//venv=default` flag as part of
your `.bazelrc`, because then the scope of where that default is applied is well
bounded to your repository with your hub.

We could allow the `_main` repository to set a default venv name, but the
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
