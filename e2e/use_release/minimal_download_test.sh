#!/usr/bin/env bash

set -o errexit -o pipefail -o nounset

OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(arch)"
ALLOWED="rules_py_tools.${OS}_${ARCH}"
if [ "$ARCH" == "x86_64" ]; then
    ALLOWED="rules_py_tools.${OS}_amd64"
fi

# FIXME: Find a port we can bind.
PORT=7654
touch devserver.pid
PIDFILE=$(realpath ./devserver.pid)

(
    cd ../../

    # First we produce a release artifact matrix
    mkdir artifacts
    DEST=$(realpath artifacts) bazel run //tools/release:copy_release_artifacts

    # We kick off a dev http server on localhost
    #
    # Bazel will block until the devserver starts, then it forks to the background
    # which will unblock the Bazel server & shell execution.
    bazel run //tools/e2e:fileserver -- --port=$PORT --dir="$(realpath ./artifacts)" --background --pidfile="$PIDFILE"

    # Now we need to update the integrity file
    bazel run //tools/e2e:integrity -- --dir="$(realpath ./artifacts)" --target="$(realpath ./tools/integrity.bzl)"

    # Note that we don't have to scrub the bazel server because we're using a separate output_base below for the cases.
)

# Set an environment flag which will make rules_py treat localhost as a mirror/artifact source
export RULES_PY_RELEASE_URL="http://localhost:$PORT/{filename}"

#############
# Test bzlmod
(
    cd ../..
    # Create the .orig file, whether there's a mismatch or not
    patch -p1 --backup < .bcr/patches/*.patch
)

OUTPUT_BASE=$(mktemp -d)
output=$(bazel "--output_base=$OUTPUT_BASE" run --enable_bzlmod //src:main)
if [[ "$output" != "hello world" ]]; then
  >&2 echo "ERROR: bazel command did not produce expected output"
  exit 1
fi
externals=$(ls $OUTPUT_BASE/external)

if echo "$externals" | grep -v "${ALLOWED}" | grep -v ".marker" | grep rules_py_tools.
then
    >&2 echo "ERROR: rules_py binaries were fetched for platform other than ${ALLOWED}"
    exit 1
fi
if echo "$externals" | grep rust
then
    >&2 echo "ERROR: we fetched a rust repository"
    exit 1
fi

#############
# Test WORKSPACE
OUTPUT_BASE=$(mktemp -d)
output=$(bazel "--output_base=$OUTPUT_BASE" run --noenable_bzlmod //src:main)
if [[ "$output" != "hello world" ]]; then
  >&2 echo "ERROR: bazel command did not produce expected output"
  exit 1
fi

externals=$(ls $OUTPUT_BASE/external)

if echo "$externals" | grep -v "${ALLOWED}" | grep -v ".marker" | grep rules_py_tools.
then
    >&2 echo "ERROR: rules_py binaries were fetched for platform other than ${ALLOWED}"
    exit 1
fi
if echo "$externals" | grep rust
then
    >&2 echo "ERROR: we fetched a rust repository"
    exit 1
fi

#############
# Smoke test
bazel test --test_output=streamed //...

(
    cd ../..
    rm MODULE.bazel
    mv MODULE.bazel.orig MODULE.bazel
)

#############
# Smoke test py_venv examples
(
  cd ../..
  bazel run //examples/py_venv:venv -- -c 'print("Hello, world")'
  bazel run //examples/py_venv:internal_venv
  bazel run --stamp //examples/py_venv:internal_venv
  bazel run //examples/py_venv:external_venv
  bazel run --stamp //examples/py_venv:external_venv
)

# Shut down the devserver
kill "$PIDFILE"
