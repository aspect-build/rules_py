# Rewrites mtree rows whose `content=` path is actually a symlink into
# `type=link` rows, so bsdtar preserves them as symlinks instead of
# following and inlining the target bytes.
#
# Forked from @tar.bzl//tar/private:preserve_symlinks.awk. Three
# behavioural differences, each proposed upstream as
# https://github.com/bazel-contrib/tar.bzl/pull/107:
#
#   1. Try plain `readlink` first and keep its result when relative —
#      preserves authored `declare_symlink + target_path` strings
#      verbatim in the archive instead of canonicalising via `-f`.
#   2. Accept any `bazel-out/<cfg>/bin/` (not only the mtree_mutate
#      action's own `bin_dir`) so transitioned-config symlinks get
#      classified.
#   3. Accept `external/<repo>/` paths so symlinks to external-repo
#      files (e.g. rules_python's interpreter tree) are detected.
#
# Retire this file + the `mtree_preserve_symlinks` rule once that PR
# merges and we bump tar.bzl; py_image_layer reverts to
# `mtree_mutate(preserve_symlinks = True)`.
#
# TODO: PR #107 merged 2026-05-05 but this fork still
# diverges from upstream — our `else if` between the `bazel-out/` and
# `external/` sub() calls (see the "Accept absolute paths..." block
# below) is not yet on tar.bzl's main. Without it, paths that match
# both regexes (e.g. `bazel-out/<cfg>/bin/external/<repo>/...`, the
# canonical shape of any generated wheel file) get over-stripped to
# `external/<repo>/...`, miss the `symlink_map` lookup, and end up as
# literal dangling targets inside OCI layers. Send a follow-up PR to
# bazel-contrib/tar.bzl and bump past the release containing it before
# retiring this file, otherwise the bug walks back in.
#
# Invoked by the `mtree_preserve_symlinks` rule in
# [mtree_preserve_symlinks.bzl](mtree_preserve_symlinks.bzl), which
# shells out to the host `awk`. Self-contained, POSIX awk only.
#
# Optional -v owner=<n> and -v group=<n> variables stamp uid/gid onto
# every line. Missing → lines pass through unchanged.

function common_sections(path1, path2, i, segments1, segments2, min_length, common_path) {
    gsub(/^\/|\/$/, "", path1)
    gsub(/^\/|\/$/, "", path2)
    split(path1, segments1, "/")
    split(path2, segments2, "/")
    min_length = (length(segments1) < length(segments2)) ? length(segments1) : length(segments2)
    common_path = ""
    for (i = 1; i <= min_length; i++) {
        if (segments1[i] != segments2[i]) {
            break
        }
        common_path = (common_path == "" ? segments1[i] : common_path "/" segments1[i])
    }
    return common_path
}

function make_relative_link(path1, path2, i, common, target, relative_path, back_steps) {
    # Returns a relative path from path2's directory (path2 points at a
    # FILE, so its "location" for relative-symlink resolution is the
    # PARENT of that file) to path1.
    #
    # `path2_segments` counts file + intermediate dirs; to walk from
    # path2's parent dir up to the common prefix we need (len - 1) `../`
    # — one for each intermediate directory, NOT counting the file
    # itself.
    common = common_sections(path1, path2)
    target = substr(path1, length(common) + 2)
    relative_path = substr(path2, length(common) + 2)
    split(relative_path, path2_segments, "/")
    back_steps = ""
    for (i = 1; i < length(path2_segments); i++) {
        back_steps = back_steps "../"
    }
    return back_steps target
}

{
    if (owner != "") {
        sub(/uid=[0-9]+/, "uid=" owner)
    }
    if (group != "") {
        sub(/gid=[0-9]+/, "gid=" group)
    }

    symlink = ""
    symlink_content = ""
    if ($0 ~ /type=file/ && $0 ~ /content=/) {
        match($0, /content=[^ ]+/)
        content_field = substr($0, RSTART, RLENGTH)
        split(content_field, parts, "=")
        path = parts[2]
        symlink_map[path] = $1

        # Determine the effective symlink target.
        #
        # Plain `readlink` returns the raw first-hop target. For
        # `declare_symlink` outputs with a relative target_path (e.g.
        # `../../../_wheels/0/...`), that's exactly the string we want
        # to preserve verbatim in the tar.
        #
        # But plain readlink is NOT enough on its own: when this action
        # runs sandboxed, each input is staged as a sandbox-local symlink
        # pointing at the main execroot, so plain readlink on
        # `bazel-out/.../bin/.../bin/python` returns
        # `/private/.../execroot/_main/bazel-out/.../bin/.../bin/python`
        # — just the same file with a different prefix, telling us
        # nothing about whether the SOURCE bin/python is itself a
        # symlink in the archive. `readlink -f` walks the full chain to
        # the final canonical target and handles that case.
        #
        # So: keep plain readlink's answer ONLY when it's a relative
        # `..`-prefixed target (the case plain readlink uniquely
        # preserves); otherwise fall through to `readlink -f`.
        raw_readlink = ""
        cmd = "readlink \"" path "\" 2>/dev/null"
        cmd | getline raw_readlink
        close(cmd)
        resolved_path = ""
        if (raw_readlink != "" && raw_readlink !~ /^\//) {
            # Relative target — declare_symlink output. Preserve verbatim:
            # relative targets are calibrated for their location in the
            # output tree and should land in the tar unchanged.
            symlink = raw_readlink
            symlink_content = path
            resolved_path = raw_readlink
        } else {
            # Empty (not a symlink) or absolute (plain readlink returned
            # the sandbox→main-execroot mapping, which is uninformative).
            # Canonicalize via `readlink -f` and classify by where the
            # final target lives.
            cmd = "readlink -f \"" path "\" 2>/dev/null"
            cmd | getline resolved_path
            close(cmd)

            # Accept absolute paths that live under `bazel-out/<cfg>/bin/`
            # (venv / declare_file outputs), `external/<repo>/` (the
            # rules_python interpreter tree lives here directly, not
            # under bazel-out), or the Bazel-9 content-addressable repo
            # store at `<output_base>/cache/repos/v1/contents/<content
            # -hash>/<extraction-id>/...`. Normalise to the execroot-
            # relative form so `symlink_map` lookups (keyed by the
            # mtree's `content=` field, also execroot-relative) can find
            # a match.
            #
            # The first two branches are mutually exclusive in the
            # over-strip sense: a generated wheel file lives at
            # `bazel-out/<cfg>/bin/external/<repo>/...`, so both regexes
            # match. Prefer the bazel-out form — it's the canonical key
            # used by symlink_map for generated files — otherwise we'd
            # over-strip down to `external/<repo>/...` and miss the
            # lookup, leaving the link as a literal `external/<repo>/...`
            # that dangles inside an OCI layer.
            #
            # The CAS branch handles Bazel 9 specifically: it materialises
            # external repo content under
            # `<output_base>/cache/repos/v1/contents/<hash>/<uuid>/...`,
            # with `<output_base>/external/<repo>` a top-level symlink
            # pointing at that CAS directory. `readlink -f` walks all the
            # way through the chain — sandbox→execroot symlink → external
            # repo symlink → CAS dir → intra-repo relative symlink — and
            # returns a CAS-absolute path that contains neither `bazel-
            # out/<cfg>/bin/` nor `/external/`. Without this branch, the
            # row falls through to the empty `else` and stays as
            # `type=file`, producing duplicate-content layers (e.g. three
            # real interpreter binaries `python`, `python3`, `python3.11`
            # instead of two symlinks + one real file). The CAS path's
            # repo-relative tail (after the `<hash>/<uuid>/` segments) is
            # the same suffix the original input had after its
            # `external/<repo>/` prefix; reattach the input's
            # `external/<repo>/` so the result matches a `symlink_map`
            # entry (which is keyed by mtree-form `external/<repo>/...`).
            if (resolved_path ~ /\/bazel-out\/[^\/]+\/bin\//) {
                sub(/^.*\/bazel-out\//, "bazel-out/", resolved_path)
            } else if (resolved_path ~ /\/external\//) {
                sub(/^.*\/external\//, "external/", resolved_path)
            } else if (resolved_path ~ /\/cache\/repos\/v1\/contents\/[^\/]+\/[^\/]+\//) {
                if (match(path, /^external\/[^\/]+\//)) {
                    repo_prefix = substr(path, RSTART, RLENGTH)
                    sub(/^.*\/cache\/repos\/v1\/contents\/[^\/]+\/[^\/]+\//, "", resolved_path)
                    resolved_path = repo_prefix resolved_path
                } else {
                    resolved_path = ""
                }
            } else {
                resolved_path = ""
            }
            if (resolved_path != "" && path != resolved_path) {
                symlink = resolved_path
                symlink_content = path
            }
        }
    }
    if (symlink != "") {
        line_array[NR] = $0 SUBSEP $1 SUBSEP resolved_path
    } else {
        line_array[NR] = $0
    }
    next;
}

END {
    for (i = 1; i <= NR; i++) {
        line = line_array[i]
        if (index(line, SUBSEP) > 0) {
            split(line, fields, SUBSEP)
            original_line = fields[1]
            field0 = fields[2]
            resolved_path = fields[3]
            if (resolved_path in symlink_map) {
                mapped_link = symlink_map[resolved_path]
                linked_to = make_relative_link(mapped_link, field0)
            } else {
                linked_to = resolved_path
            }
            sub(/type=[^ ]+/, "type=link", original_line)
            sub(/content=[^ ]+/, "link=" linked_to, original_line)
            print original_line
        } else {
            print line
        }
    }
}
