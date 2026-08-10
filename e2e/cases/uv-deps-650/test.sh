#!/usr/bin/env bash
#
# Runtime smoke for the cross-built geohash images.
#
# The ELF checks in crossbuild/BUILD.bazel prove the cross-compiled extension
# has the right architecture bytes; this proves it imports and executes on the
# target architecture. dlopen resolves the symbols an ELF shared link is
# allowed to leave undefined, so a wheel that "linked fine" without its C++
# runtime fails here and nowhere else. Needs a real `bazel run` (oci_load)
# plus a container daemon, so it cannot be an sh_test under //....
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BAZEL="${BAZEL:-bazel}"
PKG="//uv-deps-650/crossbuild"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: no usable container daemon; cross-arch runtime smoke not run"
    exit 0
fi

status=0

smoke() {
    local leg="$1" expected_machine="$2"
    local tag="rules-py/geohash-crossbuild:${leg}"
    local platform="linux/${leg}"

    echo "== ${leg}: build and load image =="
    if ! "$BAZEL" run "${PKG}:geohash_${leg}_image_load"; then
        echo "FAIL: ${leg}: building/loading the image failed" >&2
        status=1
        return 0
    fi

    # Infra probe, separate from the product check: /bin/true comes from the
    # ubuntu base layer, so if even that cannot exec, this host lacks binfmt
    # emulation for ${platform} — an environment gap, not a product bug.
    # GitHub's ubuntu runners ship no handlers; install them once.
    if ! docker run --rm --platform "${platform}" --entrypoint /bin/true "${tag}" >/dev/null 2>&1; then
        if [ "$(uname -s)" = "Linux" ]; then
            docker run --privileged --rm tonistiigi/binfmt --install "${leg}" >/dev/null 2>&1 || true
        fi
        if ! docker run --rm --platform "${platform}" --entrypoint /bin/true "${tag}" >/dev/null 2>&1; then
            echo "SKIP: ${leg}: no ${platform} emulation available on this host"
            return 0
        fi
    fi

    echo "== ${leg}: run the extension on ${platform} =="
    local output
    if ! output="$(docker run --rm --platform "${platform}" "${tag}" 2>&1)"; then
        echo "${output}" >&2
        echo "FAIL: ${leg}: geohash smoke exited nonzero" >&2
        status=1
        return 0
    fi
    echo "${output}"
    if ! grep -q "GEOHASH_SMOKE_OK" <<<"${output}"; then
        echo "FAIL: ${leg}: smoke ran but did not report GEOHASH_SMOKE_OK" >&2
        status=1
        return 0
    fi
    if ! grep -q "machine=${expected_machine}" <<<"${output}"; then
        echo "FAIL: ${leg}: expected machine=${expected_machine} in output" >&2
        status=1
        return 0
    fi
    echo "PASS: ${leg} extension executed on ${platform}"
}

smoke arm64 aarch64
smoke amd64 x86_64

exit "${status}"
