# Rewrites mtree rows whose `content=` path is actually a symlink into
# `type=link` rows, so bsdtar preserves them as symlinks instead of
# following and inlining the target bytes.
#
# Forked from @tar.bzl//tar/private:preserve_symlinks.awk and tracking
# https://github.com/bazel-contrib/tar.bzl/pull/115. One behavioural
# difference remains:
#
#   The `bazel-out/` vs `external/` strip is exclusive (`if` / `else if`)
#   rather than two sequential `sub`s. Without this, paths matching
#   both regexes — e.g. `bazel-out/<cfg>/bin/external/<repo>/...`,
#   the canonical shape of a generated wheel file — get
#   over-stripped down to `external/<repo>/...`, miss the
#   `symlink_map` lookup, and dangle inside the OCI layer.
#
# Send a follow-up PR to bazel-contrib/tar.bzl once #115
# lands so this fork can retire.
#
# Invoked from `_run_tar_action` in [py_image_layer.bzl](py_image_layer.bzl)
# via `ctx.executable._awk` pinned to `@gawk` — the END block uses
# `asort()` and `print > outfile`, both gawk extensions.

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
    target = path1
    relative_path = path2

    common = common_sections(path1, path2)
    if (common != "") {
        target = substr(path1, length(common) + 2)
        relative_path = substr(path2, length(common) + 2)
    }

    # Walk up from path2's PARENT directory (path2 identifies a file —
    # its location for relative-symlink resolution is the parent of
    # that file). For an N-segment relative_path, N-1 are intermediate
    # directories.
    split(relative_path, path2_segments, "/")
    back_steps = ""
    for (i = 1; i < length(path2_segments); i++) {
        back_steps = back_steps "../"
    }
    return back_steps target
}

function normalize_destination(path, count, i, n, part, parts, normalized) {
    count = split(path, parts, "/")
    n = 0
    for (i = 1; i <= count; i++) {
        part = parts[i]
        if (part == "" || part == ".") {
            continue
        }
        if (part == "..") {
            if (n == 0) {
                print "py_image_layer image destination escapes its root: " path > "/dev/stderr"
                failed = 1
                exit 1
            }
            delete normalized[n--]
            continue
        }
        normalized[++n] = part
    }
    path = "."
    for (i = 1; i <= n; i++) {
        path = path "/" normalized[i]
    }
    return path
}

{
    if ($0 !~ /^#/) {
        destination = normalize_destination($1)
        sub(/^[^ ]+/, destination)
        match($0, /(contents|content|link)=[^ ]+/)
        current_source = substr($0, RSTART, RLENGTH)
        current_source_path = substr(current_source, index(current_source, "=") + 1)
        if (destination in destination_rows) {
            if (destination_rows[destination] == $0 || (validate_only && destination_source_paths[destination] == current_source_path)) {
                next
            }
            print "py_image_layer runfile collision at " destination ": " destination_sources[destination] " and " current_source > "/dev/stderr"
            failed = 1
            exit 1
        }
        destination_rows[destination] = $0
        destination_sources[destination] = current_source
        destination_source_paths[destination] = current_source_path
    }

    if (validate_only) {
        next
    }

    symlink = ""
    symlink_content = ""
    # Two markers Starlark emits for paths that could be symlinks:
    #   - `type=link link=<exec_path>` — hot path. `f.is_symlink` was set, so
    #     `readlink` always returns a target; we just resolve and rewrite.
    #   - `type=file content=<exec_path>` — slow fallback. Catches files that
    #     might be symlinks Bazel didn't flag (repo-rule-staged ones like
    #     rules_python's `bin/python -> python3.11`). Empty `readlink` means
    #     it's a regular file and the row passes through unchanged.
    is_hot_path = ($0 ~ /type=link/) && ($0 ~ /link=/)
    is_slow_path = ($0 ~ /type=file/) && ($0 ~ /content=/)
    if (is_hot_path || is_slow_path) {
        if (is_hot_path) {
            match($0, /link=[^ ]+/)
        } else {
            match($0, /content=[^ ]+/)
        }
        content_field = substr($0, RSTART, RLENGTH)
        split(content_field, parts, "=")
        path = parts[2]
        symlink_map[path] = $1

        # Plain `readlink` first: keep its result if relative
        # (`declare_symlink`'s authored `target_path`) or absolute under
        # the Bazel tree. We MUST NOT call `readlink -f` on the latter:
        # under Bazel 9's content-addressed repo layout,
        # `external/<repo>/` is itself a symlink into
        # `<cache>/repos/v1/contents/<sha>/<uuid>/`, and `-f` would walk
        # through it and lose the `external/<repo>/` form the
        # `symlink_map` lookup needs.
        raw_readlink = ""
        cmd = "readlink \"" path "\""
        cmd | getline raw_readlink
        close(cmd)

        # Sandboxed actions mount each input as a symlink whose target
        # repeats the input path under `/.../execroot/_main/`. That
        # hop is uninformative — read one more so we see the symlink
        # the action's source actually wrote.
        if (raw_readlink != "" && raw_readlink ~ /^\//) {
            suffix = "/" path
            suffix_start = length(raw_readlink) - length(suffix) + 1
            if (suffix_start > 0 && substr(raw_readlink, suffix_start) == suffix) {
                cmd = "readlink \"" raw_readlink "\""
                next_link = ""
                cmd | getline next_link
                close(cmd)
                raw_readlink = next_link
            }
        }

        resolved_path = ""
        if (raw_readlink != "" && raw_readlink !~ /^\//) {
            resolved_path = raw_readlink
        } else if (raw_readlink ~ /\/bazel-out\/[^\/]+\/bin\// || raw_readlink ~ /\/external\//) {
            resolved_path = raw_readlink
        } else {
            cmd = "readlink -f \"" path "\""
            cmd | getline resolved_path
            close(cmd)
        }

        if (resolved_path) {
            if (resolved_path !~ /^\//) {
                # Relative target — `declare_symlink` output or an
                # intra-dir chain (e.g. `python -> python3.11`). Keep
                # verbatim; it's already in tar-entry form.
                symlink = resolved_path
                symlink_content = path
            } else if (resolved_path ~ /\/bazel-out\/[^\/]+\/bin\// || \
                       resolved_path ~ /\/external\//) {
                # Absolute path under the Bazel tree. Normalise to the
                # execroot-relative form `symlink_map` is keyed by.
                #
                # Order matters: a generated wheel file lives at
                # `bazel-out/<cfg>/bin/external/<repo>/...` so both
                # regexes match — strip the longer `bazel-out/<cfg>/bin/`
                # prefix exclusively, otherwise we'd over-strip down to
                # `external/<repo>/...` and miss the lookup.
                if (resolved_path ~ /\/bazel-out\/[^\/]+\/bin\//) {
                    sub(/^.*\/bazel-out\//, "bazel-out/", resolved_path)
                } else {
                    sub(/^.*\/external\//, "external/", resolved_path)
                }
                if (path != resolved_path) {
                    symlink = resolved_path
                    symlink_content = path
                }
            }
        }
    }
    if (symlink != "") {
        line_array[++row_count] = $0 SUBSEP $1 SUBSEP resolved_path
    } else {
        line_array[++row_count] = $0
    }
}

END {
    if (failed) {
        exit 1
    }
    if (validate_only) {
        print "#mtree" > outfile
        exit
    }
    # Buffer rewritten rows, sort byte-wise (asort under LC_ALL=C, set by
    # the action env), and write to `outfile`.
    n = 0
    for (i = 1; i <= row_count; i++) {
        line = line_array[i]
        if (index(line, SUBSEP) > 0) {
            split(line, fields, SUBSEP)
            original_line = fields[1]
            field0 = fields[2]
            resolved_path = fields[3]
            if (resolved_path in symlink_map) {
                mapped_link = symlink_map[resolved_path]
                linked_to = make_relative_link(mapped_link, field0)
            } else if (resolved_path ~ /^bazel-out\// || resolved_path ~ /^external\//) {
                # Classified to a Bazel-tree path but the target row
                # isn't in this layer's mtree — a config bug. Emit a
                # dangling `type=link link=...` to surface it visibly.
                linked_to = resolved_path
            } else {
                # Already a relative path
                linked_to = resolved_path
            }
            sub(/type=[^ ]+/, "type=link", original_line)
            if (!sub(/content=[^ ]+/, "link=" linked_to, original_line)) {
                sub(/link=[^ ]+/, "link=" linked_to, original_line)
            }
            out_lines[++n] = original_line
        } else {
            out_lines[++n] = line
        }
    }
    asort(out_lines)
    for (i = 1; i <= n; i++) {
        print out_lines[i] > outfile
    }
}
