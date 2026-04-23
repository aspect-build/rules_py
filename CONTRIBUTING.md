# How to Contribute

## Formatting

Starlark files should be formatted by buildifier.
We suggest using a pre-commit hook to automate this.
First [install pre-commit](https://pre-commit.com/#installation),
then run

```shell
pre-commit install
```

Otherwise later tooling on CI may yell at you about formatting/linting violations.

## Updating BUILD files

Some targets are generated from sources.
Currently this is just the `bzl_library` targets.
Run `bazel run //:gazelle` to keep them up-to-date.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another WORKSPACE, such as
some other ruleset that depends on rules_py, or in a nested
WORKSPACE in the integration_tests folder.

To always tell Bazel to use this directory rather than some release
artifact or a version fetched from the internet, run this from this
directory:

```sh
OVERRIDE="--override_repository=aspect_rules_py=$(pwd)/rules_py"
echo "common $OVERRIDE" >> ~/.bazelrc
```

This means that any usage of `@aspect_rules_py` on your system will point to this folder.

## Running `uv` from the Bazel-managed toolchain

`MODULE.bazel` registers a hermetic `uv` via `uv.toolchain(version = "…")`, so
there's no need to install `uv` globally. Two ways to invoke it:

### Ad-hoc: `bazel run`

```sh
bazel run @uv -- lock
bazel run @uv -- add --no-workspace requests
```

`@uv` is an alias that resolves to the host-platform UV binary for the
version configured in `MODULE.bazel`.

### On your `$PATH` via `bazel_env.bzl`

`//tools:bazel_env` maps `uv` (and `cargo`, `rustc`, `rustfmt`, multitool
binaries) to Bazel labels and materializes them into
`bazel-out/bazel_env-opt/bin/tools/bazel_env/bin/`. Pair it with
[direnv](https://direnv.net/):

1. `bazel run //tools:bazel_env` once (and again whenever versions change).
2. Create a `.envrc` next to `MODULE.bazel`:

   ```sh
   watch_file bazel-out/bazel_env-opt/bin/tools/bazel_env/bin
   PATH_add bazel-out/bazel_env-opt/bin/tools/bazel_env/bin
   if [[ ! -d bazel-out/bazel_env-opt/bin/tools/bazel_env/bin ]]; then
     log_error "Run 'bazel run //tools:bazel_env'"
   fi
   ```

3. `direnv allow`.

Now `uv lock`, `uv add`, etc. resolve to the Bazel-managed binary anywhere in
the workspace.

## Releasing

1. Determine the next release version, following semver (could automate in the future from changelog)
1. Tag the repo and push it (or create a tag in GH UI)
1. Watch the automation run on GitHub actions
