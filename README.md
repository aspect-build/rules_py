1. if you don't need to fetch platform-dependent tools, then remove anything toolchain-related.
1. update the `actions/cache@v2` bazel cache key in [.github/workflows/ci.yaml](.github/workflows/ci.yaml) and [.github/workflows/release.yml](.github/workflows/release.yml) to be a hash of your source files.
1. delete this section of the README (everything up to the SNIP).

---- SNIP ----

# Bazel rules for py

## Installation

From the release you wish to use:
<https://github.com/aspect-build/rules_py/releases>
copy the WORKSPACE snippet into your `WORKSPACE` file.
