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

gzip < $ARCHIVE_TMP > $ARCHIVE
SHA=$(shasum -a 256 $ARCHIVE | awk '{print $1}')

# Add generated API docs to the release, see https://github.com/bazelbuild/bazel-central-registry/issues/5593
"$(dirname "$0")/release_docs.sh" "$GITHUB_WORKSPACE/${ARCHIVE%.tar.gz}.docs.tar.gz"

cat << EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "aspect_rules_py", version = "${TAG:1}")
\`\`\`

And also register a Python toolchain, see rules_python. For example:

\`\`\`starlark
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(
    python_version = "3.13",
)
\`\`\`

EOF
