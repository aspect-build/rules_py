#!/usr/bin/env bash
#
# Asserts that sdist_build repositories are served from the remote repo
# contents cache. Client A populates a gRPC cache; clients B and C start empty
# and must reuse A's results instead of running the rule. Every client gets a
# fresh --output_user_root, so its local repo contents cache starts empty and
# any hit can only come from the remote.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
BAZEL="${BAZEL:-bazel}"
# --experimental_remote_repo_contents_cache first shipped in Bazel 8.8.0. The
# bazel-8 CI leg exports an empty USE_BAZEL_VERSION (the workspace's 8.6.0).
export USE_BAZEL_VERSION="${USE_BAZEL_VERSION:-8.8.0}"

BAZEL_REMOTE_VERSION="2.6.2"
bazel_remote_sha256() {
    case "$1" in
        darwin-amd64) echo fc3b8f5d8edcf94f578cf6ffa8071d8859f5f02a38c14ae00cd3d22aa44974b6 ;;
        darwin-arm64) echo 1d6bc5fe5be7a66c7aeea6723280402414e280ae579016d3b5e6e5c77278ad04 ;;
        linux-amd64) echo 62e236bf8396e69396928e0d0c32062fbd5575f20fe55dc10a82eb791297e1a0 ;;
        linux-arm64) echo b2cabd5bf674e8d0649de2c95dddfea8d875db1a06ed9d431674c9293df273ed ;;
    esac
}

SDIST_BUILD_REPOS=(
    sdist_build__remote_repo_contents_cache__docopt__0_6_2
    sdist_build__remote_repo_contents_cache__hurry_filesize__0_9
    sdist_build__remote_repo_contents_cache__sgmllib3k__1_0_0
)

# Kept short: unix socket paths are capped at 104 bytes on macOS.
work="$(mktemp -d "${TMPDIR:-/tmp}/rrcc.XXXXXX")"
cache_pid=""
clients=()

cleanup() {
    local client
    for client in "${clients[@]}"; do
        (cd "$case_dir" && "$BAZEL" --output_user_root="$work/$client" shutdown) >/dev/null 2>&1
    done
    [ -n "$cache_pid" ] && kill "$cache_pid" 2>/dev/null
    chmod -R u+w "$work" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

bazel_remote_binary() {
    if [ -n "${BAZEL_REMOTE:-}" ]; then
        echo "$BAZEL_REMOTE"
        return
    fi
    local os arch platform binary
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$(uname -m)" in
        x86_64 | amd64) arch=amd64 ;;
        arm64 | aarch64) arch=arm64 ;;
        *) echo "unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
    platform="$os-$arch"
    binary="$work/bazel-remote"
    curl -fsSL -o "$binary" \
        "https://github.com/buchgr/bazel-remote/releases/download/v$BAZEL_REMOTE_VERSION/bazel-remote-$BAZEL_REMOTE_VERSION-$platform" ||
        return 1
    if [ "$(sha256 "$binary")" != "$(bazel_remote_sha256 "$platform")" ]; then
        echo "bazel-remote $platform sha256 mismatch" >&2
        return 1
    fi
    chmod +x "$binary"
    echo "$binary"
}

start_cache() {
    local binary
    binary="$(bazel_remote_binary)" || exit 1
    "$binary" --dir "$work/cas" --max_size 4 \
        --grpc_address "unix://$work/grpc.sock" \
        --http_address "unix://$work/http.sock" >"$work/cache.log" 2>&1 &
    cache_pid=$!
    for _ in $(seq 50); do
        [ -S "$work/grpc.sock" ] && return
        sleep 0.1
    done
    cat "$work/cache.log" >&2
    echo "bazel-remote did not start" >&2
    exit 1
}

# run_client <name> <log> <bazel command and args...>
run_client() {
    local client="$1" log="$2"
    shift 2
    clients+=("$client")
    (
        cd "$case_dir" &&
            "$BAZEL" \
                --nohome_rc --nosystem_rc \
                --output_user_root="$work/$client" \
                --experimental_remote_repo_contents_cache \
                "$@" \
                --lockfile_mode=off \
                --remote_cache="unix://$work/grpc.sock" \
                --remote_upload_local_results \
                --repo_env=DO_NOT_TRACK=1
    ) >"$log" 2>&1
}

external_dir() {
    echo "$(cd "$case_dir" && "$BAZEL" --output_user_root="$work/$1" info output_base 2>/dev/null)/external"
}

# A marker exists only for a repository whose rule ran in this client. With an
# empty local repo contents cache, a missing one means a remote cache hit.
ran_in() {
    compgen -G "$(external_dir "$1")/@*$2.marker" >/dev/null
}

fetched_in() {
    compgen -G "$(external_dir "$1")/*$2" >/dev/null
}

ac_uploads() {
    grep -c "AC PUT" "$work/cache.log"
}

echo "Bazel $("$BAZEL" --version 2>/dev/null) / USE_BAZEL_VERSION=$USE_BAZEL_VERSION"
start_cache

if ! run_client populate "$work/populate.log" build --nobuild //:consumer; then
    cat "$work/populate.log" >&2
    echo "FAIL: populating client did not analyze //:consumer" >&2
    exit 1
fi

uploads_before_consume="$(ac_uploads)"
if ! run_client consume "$work/consume.log" build --nobuild //:consumer; then
    cat "$work/consume.log" >&2
    echo "FAIL: consuming client did not analyze //:consumer" >&2
    exit 1
fi

ran_in consume cache_probe_nonreproducible ||
    fail "control: the non-reproducible probe did not run, so the consuming client was not cold"
ran_in consume cache_probe_reproducible &&
    fail "control: the reproducible probe ran again, so the remote cache did not round-trip"

for repo in "${SDIST_BUILD_REPOS[@]}"; do
    if ! fetched_in consume "$repo"; then
        fail "@$repo was never requested by //:consumer"
    elif ran_in consume "$repo"; then
        fail "@$repo ran in the consuming client instead of coming from the remote cache"
    fi
done

consume_uploads=$(($(ac_uploads) - uploads_before_consume))
[ "$consume_uploads" -eq 0 ] ||
    fail "the consuming client uploaded $consume_uploads action cache entries; something missed the cache"

# Loading the sdist_build packages alone must not need the interpreter on disk.
query_targets="$(printf '@%s//:all + ' "${SDIST_BUILD_REPOS[@]}")"
if ! run_client query "$work/query.log" query "${query_targets% + }"; then
    cat "$work/query.log" >&2
    fail "the querying client could not load the sdist_build packages"
elif grep -E "Materializing remote repo @@[^ ]*python_3_[0-9]+_" "$work/query.log" >&2; then
    fail "loading sdist_build materialized the Python interpreter"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed; client logs:" >&2
    for log in "$work"/*.log; do
        echo "::group::$(basename "$log")" >&2
        cat "$log" >&2
        echo "::endgroup::" >&2
    done
    exit 1
fi
echo "PASS: every sdist_build came from the remote repo contents cache"
