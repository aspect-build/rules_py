#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Set by GH actions, see
# https://docs.github.com/en/actions/learn-github-actions/environment-variables#default-environment-variables
TAG=${GITHUB_REF_NAME}
# The prefix is chosen to match what GitHub generates for source archives
PREFIX="rules_py-${TAG:1}"
ARCHIVE="rules_py-$TAG.tar.gz"
ARCHIVE_TMP=$(mktemp)

# NB: configuration for 'git archive' is in /.gitattributes
git archive --format=tar --prefix=${PREFIX}/ ${TAG} > $ARCHIVE_TMP

############
# BEGIN archive patching

## Generate release hashes
# Delete the placeholder file
tar --file $ARCHIVE_TMP --delete ${PREFIX}/py/private/release/integrity.bzl

# Generate an updated integrity hash set
mkdir -p ${PREFIX}/py/private/release
cat >${PREFIX}/py/private/release/integrity.bzl <<EOF
"Generated during release by release_prep.sh, using integrity.jq"

RELEASED_BINARY_INTEGRITY = $(jq \
  --from-file .github/workflows/integrity.jq \
  --slurp \
  --raw-input artifacts*/*.sha256 \
)
EOF

# Append that generated file back into the archive
tar --file $ARCHIVE_TMP --append ${PREFIX}/py/private/release/integrity.bzl

# END patch up the archive
############

gzip < $ARCHIVE_TMP > $ARCHIVE
SHA=$(shasum -a 256 $ARCHIVE | awk '{print $1}')

# Add generated API docs to the release, see https://github.com/bazelbuild/bazel-central-registry/issues/5593
# Note, we use xargs here because the repo is on Bazel 7.4 which doesn't have the --output_file flag to bazel query
docs="$(mktemp -d)"
bazel --output_base="$docs" query --output=label 'kind("starlark_doc_extract rule", //py/...)' | xargs bazel --output_base="$docs" build
tar --create --auto-compress \
    --directory "$(bazel --output_base="$docs" info bazel-bin)" \
    --file "$GITHUB_WORKSPACE/${ARCHIVE%.tar.gz}.docs.tar.gz" .

cat << EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "aspect_rules_py", version = "${TAG:1}")
\`\`\`

And also register a Python toolchain. \`aspect_rules_py\` ships its own
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
interpreter extension; \`rules_python\` is not required as a toolchain
provider:

\`\`\`starlark
interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
interpreters.toolchain(
    python_version = "3.13",
    is_default = True,
)
use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
\`\`\`

See [docs/interpreter.md](https://github.com/aspect-build/rules_py/blob/main/docs/interpreter.md)
for multi-version setups, mirror configuration, and per-target version
pinning. If you prefer \`rules_python\`'s \`python.toolchain()\` — or
already use it in your workspace — that continues to work too; any
registered \`@bazel_tools//tools/python:toolchain_type\` toolchain is
honored.

EOF
