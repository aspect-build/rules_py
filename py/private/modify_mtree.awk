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

        # In sandboxed execution Bazel mounts each input as a symlink
        # whose target repeats the input's execroot-relative path under
        # `/.../execroot/_main/`. That hop is uninformative: it tells us
        # the file exists in the source execroot but not whether the
        # source itself is a symlink, which is what we need to classify
        # rows like rules_python's `bin/python -> python3.11`. Detect
        # that signature (raw_readlink ends with `/` + path) and follow
        # once more to see the symlink the action's source actually
        # wrote. Sandbox-layout-agnostic — works whether Bazel 9 stages
        # external repos via the content-addressed cache
        # (`/.../cache/repos/v1/contents/...`) or directly under
        # `output_base/external/<repo>/`.
        #
        # Overwrite raw_readlink unconditionally with the second-hop
        # result: if the underlying file isn't a symlink in its own
        # directory (e.g. an INSTALLER that lives inside a parent-dir
        # symlink chain), the second readlink returns empty, and the
        # subsequent classification falls through to `readlink -f`
        # which walks the parent-directory chain to the real target.
        if (raw_readlink != "" && raw_readlink ~ /^\//) {
            suffix = "/" path
            suffix_start = length(raw_readlink) - length(suffix) + 1
            if (suffix_start > 0 && substr(raw_readlink, suffix_start) == suffix) {
                cmd = "readlink \"" raw_readlink "\" 2>/dev/null"
                next_link = ""
                cmd | getline next_link
                close(cmd)
                raw_readlink = next_link
            }
        }

        resolved_path = ""
        if (raw_readlink != "" && raw_readlink !~ /^\//) {
            # Relative target — declare_symlink output or an intra-dir
            # chain inside an external repo (e.g. `python -> python3.11`).
            # Preserve verbatim: relative targets are calibrated for
            # their location in the output tree.
            resolved_path = raw_readlink
        } else if (raw_readlink ~ /\/bazel-out\/[^\/]+\/bin\// || raw_readlink ~ /\/external\//) {
            # Absolute path inside the Bazel tree — accept directly.
            # MUST NOT call `readlink -f` on `external/<repo>/...` paths:
            # under Bazel 9's content-addressed repo layout,
            # `<output_base>/external/<repo>/` is itself a symlink into
            # `/.../cache/repos/v1/contents/<sha>/<uuid>/`, and `-f`
            # would walk through it and yield a path missing the
            # `external/<repo>/` form `symlink_map` lookups need.
            resolved_path = raw_readlink
        } else {
            # Either an absolute target outside the Bazel tree, or no
            # second-hop result (the underlying file isn't itself a
            # symlink in its own directory but lives inside a parent-dir
            # symlink chain — e.g. `_wheels/0/<pkg>/.dist-info/INSTALLER`
            # where `_wheels/0` is the symlink redirecting into a
            # wheel-install repo). Canonicalize via `readlink -f`: it
            # walks the parent-directory chain to the real target,
            # which lives under `bazel-out/<cfg>/bin/external/<repo>/`
            # and matches the regex below.
            cmd = "readlink -f \"" path "\" 2>/dev/null"
            cmd | getline resolved_path
            close(cmd)
        }

        # Normalise absolute Bazel-tree paths to the execroot-relative
        # form `symlink_map` is keyed by (the mtree's `content=` field).
        # Order matters: a generated wheel file lives at
        # `bazel-out/<cfg>/bin/external/<repo>/...` so both regexes
        # match — strip the longer `bazel-out/<cfg>/bin/` prefix first
        # otherwise we'd over-strip down to `external/<repo>/...` and
        # miss the lookup, leaving the link as a literal dangling target
        # inside an OCI layer.
        if (resolved_path ~ /^\//) {
            # Absolute path: normalise to execroot-relative if it's
            # inside the Bazel tree, otherwise drop it (e.g. real files
            # whose `readlink -f` resolves into Bazel 9's CAS at
            # `/.../cache/repos/v1/contents/<sha>/<uuid>/` — they are
            # not symlinks, they are real files reached via a parent-
            # dir redirect, and emitting them as `type=link` to the
            # CAS path would produce a dangling link inside the OCI
            # layer).
            if (resolved_path ~ /\/bazel-out\/[^\/]+\/bin\//) {
                sub(/^.*\/bazel-out\//, "bazel-out/", resolved_path)
            } else if (resolved_path ~ /\/external\//) {
                sub(/^.*\/external\//, "external/", resolved_path)
            } else {
                resolved_path = ""
            }
        }
        if (resolved_path != "" && path != resolved_path) {
            symlink = resolved_path
            symlink_content = path
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
                # Execroot-relative target that exists as another row in
                # the layer — rewrite as a relative link inside the tar.
                mapped_link = symlink_map[resolved_path]
                linked_to = make_relative_link(mapped_link, field0)
            } else if (resolved_path ~ /^bazel-out\// || resolved_path ~ /^external\//) {
                # Execroot-relative target but it's NOT in this layer's
                # mtree — emitting `type=link link=external/<repo>/...`
                # would dangle inside the OCI layer. This happens when a
                # `ctx.actions.symlink` output points at a source file
                # in another repo whose tree isn't part of the binary's
                # runfiles — e.g. bzlmod local-override repos where
                # `external/<repo>` is itself a symlink to the user's
                # source tree. Drop the classification: keep the row as
                # the original `type=file content=...` so bsdtar inlines
                # the target bytes during archive assembly.
                print original_line
                continue
            } else {
                # Bare relative target (e.g. `python3.11`, `../foo`) —
                # `declare_symlink` output or an intra-directory chain
                # that doesn't need a `symlink_map` lookup. Use verbatim.
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
