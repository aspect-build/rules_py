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
# Patch up the archive to have integrity hashes for built binaries that we downloaded in the GHA workflow.
# Now that we've run `git archive` we are free to pollute the working directory.

# Delete the placeholder file
tar --file $ARCHIVE_TMP --delete ${PREFIX}/tools/integrity.bzl

# Add trailing newlines to sha256 files. They were built with
# https://github.com/aspect-build/bazel-lib/blob/main/tools/release/hashes.bzl
for sha in $(ls artifacts-*/*.sha256); do
  echo "" >> $sha
done

mkdir -p ${PREFIX}/tools
cat >${PREFIX}/tools/integrity.bzl <<EOF
"Generated during release by release_prep.sh, using integrity.jq"

RELEASED_BINARY_INTEGRITY = $(jq \
  --from-file .github/workflows/integrity.jq \
  --slurp \
  --raw-input artifacts-*/*.sha256 \
)
EOF

# Append that generated file back into the archive
tar --file $ARCHIVE_TMP --append ${PREFIX}/tools/integrity.bzl

# END patch up the archive
############

gzip < $ARCHIVE_TMP > $ARCHIVE
SHA=$(shasum -a 256 $ARCHIVE | awk '{print $1}')

cat << EOF
## Using [Bzlmod] with Bazel 6:

Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "aspect_rules_py", version = "${TAG:1}")

EOF

# Collect the tools snippet from the use_release module file.
awk 'f;/--SNIP--/{f=1}' e2e/use_release/MODULE.bazel

cat << EOF
\`\`\`

And also register a Python toolchain, see rules_python. For example:

\`\`\`starlark
EOF

awk 'f;/--SNIP--/{f=1}' e2e/smoke/MODULE.bazel

cat << EOF
\`\`\`

[Bzlmod]: https://bazel.build/build/bzlmod

## Using WORKSPACE

\`\`\`starlark
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
http_archive(
    name = "aspect_rules_py",
    sha256 = "${SHA}",
    strip_prefix = "${PREFIX}",
    url = "https://github.com/aspect-build/rules_py/releases/download/${TAG}/${ARCHIVE}",
)
EOF

awk 'f;/--SNIP--/{f=1}' e2e/smoke/WORKSPACE.bazel
echo "\`\`\`"
