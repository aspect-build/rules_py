#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Set by GH actions, see
# https://docs.github.com/en/actions/learn-github-actions/environment-variables#default-environment-variables
TAG=${GITHUB_REF_NAME}
PREFIX="rules_mylang-${TAG:1}"
SHA=$(git archive --format=tar --prefix=${PREFIX}/ ${TAG} | gzip | shasum -a 256 | awk '{print $1}')

cat << EOF
WORKSPACE snippet:
\`\`\`starlark
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
http_archive(
    name = "com_myorg_rules_mylang",
    sha256 = "${SHA}",
    strip_prefix = "${PREFIX}",
    url = "https://github.com/myorg/rules_mylang/archive/refs/tags/${TAG}.tar.gz",
)

# Fetches the rules_mylang dependencies.
# If you want to have a different version of some dependency,
# you should fetch it *before* calling this.
# Alternatively, you can skip calling this function, so long as you've
# already fetched all the dependencies.
load("@com_myorg_rules_mylang//mylang:repositories.bzl", "rules_mylang_dependencies")
rules_mylang_dependencies()

\`\`\`
EOF
