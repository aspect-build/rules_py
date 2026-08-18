# Rewrites mtree rows whose `content=` path is actually a symlink into
# `type=link` rows, so bsdtar preserves them as symlinks instead of
# following and inlining the target bytes.
#
# Forked from @tar.bzl//tar/private:preserve_symlinks.awk. The upstream
# implementation in https://github.com/bazel-contrib/tar.bzl/pull/115 lacks
# both cross-layer target mappings and one path-normalization fix retained here.
#
#   The `bazel-out/` vs `external/` strip is exclusive (`if` / `else if`)
#   rather than two sequential `sub`s. Without this, paths matching
#   both regexes — e.g. `bazel-out/<cfg>/bin/external/<repo>/...`,
#   the canonical shape of a generated wheel file — get
#   over-stripped down to `external/<repo>/...`, miss the
#   `symlink_map` lookup, and dangle inside the OCI layer.
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

# Map an absolute Bazel-tree path to the execroot-relative form `symlink_map`
# is keyed by. Neither end of the path can be trusted to be unique: a wheel
# ships its own `external/` directory (sympy), and the output user root may
# itself sit under one (`--output_user_root=/tmp/external/cache`). So walk
# every `/bazel-out/` and `/external/` boundary left to right — longest
# candidate first — and take the one the mtree actually contains. Longest
# also settles `bazel-out/<cfg>/bin/external/<repo>/...`, where a generated
# wheel file matches both markers.
function execroot_relative(abs, candidate, rest, longest) {
    rest = abs
    longest = ""
    while (match(rest, /\/(bazel-out|external)\//)) {
        rest = substr(rest, RSTART + 1)
        if (rest in symlink_map) {
            return rest
        }
        if (longest == "") {
            longest = rest
        }
    }
    # Nothing matched. Fall back to the longest candidate so a genuine
    # misconfiguration still surfaces as a dangling link below.
    return longest
}

function decode_mtree_path(path) {
    gsub(/\\040/, " ", path)
    return path
}

# Record one path-set entry: a trailing "/" marks a directory recorded by
# root (tree artifacts are never expanded), anything else an exact path.
function add_set_entry(entry, exact, dirs) {
    entry = decode_mtree_path(entry)
    if (entry ~ /\/$/) {
        dirs[substr(entry, 1, length(entry) - 1)] = 1
    } else {
        exact[entry] = 1
    }
}

# True when `path` is an exact entry of `exact` or a descendant of a `dirs`
# directory.
function path_in_set(path, exact, dirs, prefix) {
    if (path in exact) {
        return 1
    }
    prefix = path
    while (match(prefix, /\/[^\/]*$/)) {
        prefix = substr(prefix, 1, RSTART - 1)
        if (prefix in dirs) {
            return 1
        }
    }
    return 0
}

function replace_metadata_field(row, pattern, replacement) {
    if (!match(row, pattern)) {
        return row
    }
    return substr(row, 1, RSTART) replacement substr(row, RSTART + RLENGTH)
}

{
    # Optional path set, read before the source rows: source rows matching
    # the chmod set are forced to mode=0755.
    if (chmod_argind && ARGIND == chmod_argind) {
        add_set_entry($0, chmod_set, chmod_dirs)
        next
    }

    source_field = ""
    source_type = ""
    for (field = 2; field <= NF; field++) {
        if ($field ~ /^(contents|content|link)=[^ ]+$/) {
            source_field = $field
        } else if ($field ~ /^type=[^ ]+$/) {
            source_type = substr($field, index($field, "=") + 1)
        }
    }

    if (ARGIND != source_argind) {
        if (source_field != "") {
            source_path = substr(source_field, index(source_field, "=") + 1)
            symlink_map[decode_mtree_path(source_path)] = $1
        }
        next
    }

    # Files also present in the binaries' source closure keep 0755.
    if (chmod_argind && source_field != "") {
        if (path_in_set(decode_mtree_path(substr(source_field, index(source_field, "=") + 1)), chmod_set, chmod_dirs)) {
            $0 = replace_metadata_field($0, "[[:space:]]mode=[^ ]+", "mode=0755")
        }
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
    is_hot_path = source_type == "link" && source_field ~ /^link=/
    is_slow_path = source_type == "file" && source_field ~ /^content=/
    if (is_hot_path || is_slow_path) {
        source_path = substr(source_field, index(source_field, "=") + 1)
        path = decode_mtree_path(source_path)
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
                # Absolute path under the Bazel tree. Keep it absolute here;
                # END maps it to the execroot-relative form once `symlink_map`
                # holds every row. A row whose target is its own exec path is
                # a plain file `readlink -f` echoed back, not a symlink.
                suffix = "/" path
                suffix_start = length(resolved_path) - length(suffix) + 1
                if (suffix_start <= 0 || substr(resolved_path, suffix_start) != suffix) {
                    symlink = resolved_path
                    symlink_content = path
                }
            }
        }
    }
    if (symlink != "") {
        line_array[++source_line_count] = $0 SUBSEP $1 SUBSEP resolved_path SUBSEP (is_slow_path ? "file" : "link")
    } else {
        line_array[++source_line_count] = $0
    }
}

END {
    # Buffer rewritten rows, sort byte-wise (asort under LC_ALL=C, set by
    # the action env), and write to `outfile`.
    n = 0
    for (i = 1; i <= source_line_count; i++) {
        line = line_array[i]
        if (index(line, SUBSEP) > 0) {
            split(line, fields, SUBSEP)
            original_line = fields[1]
            field0 = fields[2]
            resolved_path = fields[3]
            source_kind = fields[4]
            if (resolved_path ~ /^\//) {
                resolved_path = execroot_relative(resolved_path)
            }
            if (resolved_path in symlink_map) {
                mapped_link = symlink_map[resolved_path]
                linked_to = make_relative_link(mapped_link, field0)
            } else if (resolved_path ~ /^bazel-out\// || resolved_path ~ /^external\//) {
                if (source_kind == "file") {
                    # A regular file that only *looked* like a Bazel-tree
                    # target: `readlink -f` resolved it somewhere unmapped,
                    # e.g. a workspace reached through a symlinked path.
                    # Inlining its bytes is always correct.
                    out_lines[++n] = original_line
                    continue
                }
                # Classified to a Bazel-tree path but the target row
                # isn't in this layer's mtree — a config bug. Emit a
                # dangling `type=link link=...` to surface it visibly.
                linked_to = resolved_path
            } else {
                # Already a relative path
                linked_to = resolved_path
            }
            original_line = replace_metadata_field(original_line, "[[:space:]]type=[^ ]+", "type=link")
            if (original_line ~ /[[:space:]]content=[^ ]+/) {
                original_line = replace_metadata_field(original_line, "[[:space:]]content=[^ ]+", "link=" linked_to)
            } else {
                original_line = replace_metadata_field(original_line, "[[:space:]]link=[^ ]+", "link=" linked_to)
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
