#!/usr/bin/env bash

set -o errexit -o pipefail -o nounset

set -x

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
    # WARNING: For local testing you'll have to manually do this with
    # --platforms for linux otherwise you'll be missing artifacts. Which is
    # mighty annoying.
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
    # Write a version to the `version.bzl` file.
    # This emulates the version stamping git will do when it makes an archive.
    cat <<"EOF" > tools/version.bzl
VERSION = "999.99.9"
IS_PRERELEASE = False
EOF
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
bazel "--output_base=$OUTPUT_BASE" test --test_output=streamed //...

#############
# Smoke test py_venv_link
bazel "--output_base=$OUTPUT_BASE" run //src:venv
if ! [ -L ./.venv_named ]; then
  >&2 echo "ERROR: The named venv target failed to respect venv_name"
  exit 1
fi

#############
# Demonstrate that as configured we're fully on prebuilt toolchains even for crossbuilds
OUTPUT_BASE=$(mktemp -d)
(
  cd ../..

  # Check that the configured query doesn't use Rust for anything. If we're
  # using source toolchains, then we'll get a hit for Rust here.
  if bazel cquery 'kind("rust_binary", deps(//py/tests/py_venv_image_layer/...))' | grep "crate_index"; then
    >&2 echo "ERROR: we still have a rust dependency"
    exit 1
  fi

  # Demonstrate that we can do crossbuilds with the tool
  bazel "--output_base=$OUTPUT_BASE" build //py/tests/py_venv_image_layer/...

  # TODO: Note that we can't run and pass these tests because the old py_binary
  # implementation sees a different label for the venv tool (internal file vs
  # external repo file) and so its image tests fail if we run them here.
)

# Note that we can't check to see if we've fetched rules_rust etc. because
# despite being dev deps they're still visible from and fetched in the parent
# module, even if unused.

#############
# Smoke test py_venv examples
(
  cd ../..
  # Exercise the static venv bits
  # Note that we only really expect
  bazel "--output_base=$OUTPUT_BASE" run //examples/py_venv:venv -- -c 'print("Hello, world")'
  bazel "--output_base=$OUTPUT_BASE" run //examples/py_venv:internal_venv
  bazel "--output_base=$OUTPUT_BASE" run --stamp //examples/py_venv:internal_venv
  bazel "--output_base=$OUTPUT_BASE" run //examples/py_venv:external_venv
  bazel "--output_base=$OUTPUT_BASE" run --stamp //examples/py_venv:external_venv
)

# Note that we can't check to see if we've fetched rules_rust etc. because
# despite being dev deps they're still visible from and fetched in the parent
# module, even if unused.

# Shut down the devserver
kill "$(cat $PIDFILE)"
