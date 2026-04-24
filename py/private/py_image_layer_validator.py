#!/usr/bin/env python3
"""py_image_layer_validator — validate pip layer sizing for a py_image_layer target.

Invoked as a Bazel validation action. Fails (exit 1) with actionable `layer_tier` snippets
when the squashed pip layer exceeds a size threshold, when the OCI 127-layer hard limit is
breached, or when any individual pip package is unusually large.

Usage:
  py_image_layer_validator --threshold_mb N --output FILE [label=path ...]
    label=path  — one entry per ungrouped pip package; `label` is the canonical pip label
                  (e.g. @pip//numpy), `path` is its install directory / file.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import glob
import os
import sys

_OCI_LAYER_HARD_LIMIT = 127
_BINARY_GLOBS = {"*.so*", "*.pyd", "*.dylib", "*.dll"}
_LAYER_TIER_TARGET = "@aspect_rules_py//py:layer_tier"
_DEFAULT_LAYER_TIER_TARGET = "@aspect_rules_py//py/private:default_layer_tier"

_LAYER_COUNT_SUGGESTION_COMMENT = [
    "        # Too many layers: consolidate related packages under a shared group name.",
    "        # Example (replace with your actual packages):",
    '#         "@pip//numpy": "scipy_stack",',
    '#         "@pip//scipy": "scipy_stack",',
    '#         "@pip//nvidia_cublas_cu12": "cuda",',
    '#         "@pip//nvidia_cudnn_cu12": "cuda",',
]


def _pkg_name_from_label(label):
    """@@pip//torch:torch → torch (suitable as a Bazel target / group name)."""
    return label.split("//")[-1].split(":")[0].strip("@").replace("-", "_")


def _record_size(pkg_path):
    """Return the total installed size in bytes from dist-info/RECORD, or None if unavailable."""
    pattern = os.path.join(pkg_path, "*.dist-info", "RECORD")
    matches = glob.glob(pattern)
    if not matches:
        return None
    total = 0
    try:
        with open(matches[0], newline="", errors="replace") as fh:
            for row in csv.reader(fh):
                if len(row) >= 3 and row[2].strip():
                    with contextlib.suppress(ValueError):
                        total += int(row[2])
    except OSError:
        return None
    return total


def _dir_size(path):
    total = 0
    for dirpath, _dirnames, filenames in os.walk(path):
        for fname in filenames:
            with contextlib.suppress(OSError):
                total += os.path.getsize(os.path.join(dirpath, fname))
    return total


def _pkg_size(paths):
    """Return total installed size for a package, using RECORD when available."""
    total = 0
    for path in paths:
        if os.path.isdir(path):
            size = _record_size(path)
            total += size if size is not None else _dir_size(path)
        elif os.path.isfile(path):
            with contextlib.suppress(OSError):
                total += os.path.getsize(path)
    return total


def _pkg_is_binary(paths):
    """Return True if any install dir has Root-Is-Purelib: false in dist-info/WHEEL."""
    for path in paths:
        if not os.path.isdir(path):
            continue
        pattern = os.path.join(path, "*.dist-info", "WHEEL")
        for wheel_file in glob.glob(pattern):
            with contextlib.suppress(OSError), open(wheel_file, errors="replace") as fh:
                for line in fh:
                    key, _, value = line.partition(":")
                    if key.strip().lower() == "root-is-purelib" and value.strip().lower() == "false":
                        return True
    return False


def _find_large_files(paths, min_bytes):
    """Return (basename, size) for files at or above min_bytes, largest first."""
    results = []
    for path in paths:
        if os.path.isdir(path):
            for dirpath, _, filenames in os.walk(path):
                for fname in filenames:
                    fpath = os.path.join(dirpath, fname)
                    with contextlib.suppress(OSError):
                        size = os.path.getsize(fpath)
                        if size >= min_bytes:
                            results.append((fname, size))
        elif os.path.isfile(path):
            with contextlib.suppress(OSError):
                size = os.path.getsize(path)
                if size >= min_bytes:
                    results.append((os.path.basename(path), size))
    return sorted(results, key=lambda x: -x[1])


def _glob_for_file(basename):
    """Return a glob pattern that matches basename (no path separators)."""
    idx = basename.find(".so")
    if idx >= 0:
        suffix = basename[idx + 3:]
        if suffix == "" or (suffix and suffix[0] == "."):
            return "*.so*"
    for ext in (".pyd", ".dylib", ".dll"):
        if basename.endswith(ext):
            return "*" + ext
    _, dot, ext = basename.rpartition(".")
    if dot:
        return "*." + ext
    return basename


def _suggest_subpath_groups(label, paths, min_file_bytes):
    """Return (groups_key, group_name, display_line, is_binary) tuples for large files."""
    large_files = _find_large_files(paths, min_file_bytes)
    if not large_files:
        return []

    pattern_files = {}
    for basename, size in large_files:
        pattern_files.setdefault(_glob_for_file(basename), []).append((basename, size))

    pkg_name = _pkg_name_from_label(label)
    results = []
    for pat, files in sorted(pattern_files.items(), key=lambda kv: -sum(s for _, s in kv[1])):
        total_mb = sum(s for _, s in files) // (1024 * 1024)
        examples = ", ".join("{} ({}MB)".format(name, size // (1024 * 1024)) for name, size in files[:3])
        if len(files) > 3:
            examples += ", +{} more".format(len(files) - 3)
        slug = pat.lstrip("*").lstrip(".").replace(".", "_").replace("*", "")
        group_name = "{}_{}".format(pkg_name, slug) if slug else pkg_name
        groups_key = "{}:{}".format(label, pat)
        display_line = '        "{}": "{}",  # {} ({}MB)'.format(groups_key, group_name, examples, total_mb)
        results.append((groups_key, group_name, display_line, pat in _BINARY_GLOBS))
    return results


class _Suggestions:
    """Accumulates deduplicated layer_tier suggestions from the various check paths.

    Keys into group_lines are either a plain label (whole-package) or a `label:glob`
    (subpath). If a subpath entry lands for a label, any earlier whole-package entry
    for that same label is dropped — subpath wins.
    """

    def __init__(self):
        self.group_lines = {}
        self.compression = {}

    def add_group(self, groups_key, display_line):
        if ":" in groups_key.split("//")[-1]:
            whole_key = groups_key.rsplit(":", 1)[0]
            self.group_lines.pop(whole_key, None)
        else:
            for existing in self.group_lines:
                if existing.startswith(groups_key + ":"):
                    return
        self.group_lines.setdefault(groups_key, display_line)

    def add_compression(self, label, level):
        self.compression.setdefault(label, level)


def _add_whole_promotion(suggestions, label, size_mb, is_binary, annotation):
    """Emit a whole-package promotion suggestion (with optional compression override)."""
    pkg_name = _pkg_name_from_label(label)
    suggestions.add_group(label, '        "{}": "{}",  # {} ({}MB)'.format(label, pkg_name, annotation, size_mb))
    if is_binary:
        suggestions.add_compression(label, "1")


def _add_subpath_or_whole(suggestions, label, paths, size_mb, is_binary, per_file_threshold):
    """Emit subpath suggestions if the package has natural glob splits; otherwise whole-package."""
    subpath_suggestions = _suggest_subpath_groups(label, paths, per_file_threshold)
    if subpath_suggestions:
        for groups_key, _group_name, display_line, is_bin_glob in subpath_suggestions:
            suggestions.add_group(groups_key, display_line)
            if is_bin_glob:
                suggestions.add_compression(label, "1")
    else:
        _add_whole_promotion(suggestions, label, size_mb, is_binary, annotation="whole package")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--threshold_mb", type=int, default=200)
    parser.add_argument("--layer_count", type=int, default=0)
    parser.add_argument("--warn_layer_count", type=int, default=90)
    parser.add_argument("--output", required=True)
    parser.add_argument("pkg_paths", nargs="*", metavar="label=path")
    args = parser.parse_args()

    threshold_bytes = args.threshold_mb * 1024 * 1024
    per_file_threshold_bytes = max(threshold_bytes // 4, 10 * 1024 * 1024)

    pkg_path_map = {}
    for entry in args.pkg_paths:
        label, _, path = entry.partition("=")
        if not path:
            continue
        pkg_path_map.setdefault(label, []).append(path)

    pkg_sizes = {label: _pkg_size(paths) for label, paths in pkg_path_map.items()}
    pkg_binary = {label: _pkg_is_binary(paths) for label, paths in pkg_path_map.items()}

    messages = []
    suggestions = _Suggestions()

    layer_count_comment_lines = []
    if args.layer_count > _OCI_LAYER_HARD_LIMIT:
        messages.append(
            "ERROR: image has {} layers (OCI limit {}).".format(args.layer_count, _OCI_LAYER_HARD_LIMIT)
            + " Add groups= entries to reduce pip layer count."
        )
        layer_count_comment_lines = list(_LAYER_COUNT_SUGGESTION_COMMENT)
    elif args.layer_count > args.warn_layer_count:
        messages.append(
            "WARNING: image has {} layers (warn threshold: {}, hard limit: {}).".format(
                args.layer_count, args.warn_layer_count, _OCI_LAYER_HARD_LIMIT
            )
        )
        layer_count_comment_lines = list(_LAYER_COUNT_SUGGESTION_COMMENT)

    squashed_total = sum(pkg_sizes.values())
    if squashed_total > threshold_bytes:
        squashed_mb = squashed_total // (1024 * 1024)
        messages.append(
            "ERROR: squashed pip layer is {}MB (threshold {}MB).".format(squashed_mb, args.threshold_mb)
            + " Promote the largest ungrouped packages below into layer_tier to shrink it."
        )
        for label, size in sorted(pkg_sizes.items(), key=lambda kv: -kv[1])[:15]:
            mb = size // (1024 * 1024)
            if mb < 1:
                break
            _add_whole_promotion(suggestions, label, mb, pkg_binary.get(label, False), annotation="")

    binary_below_threshold = []
    for label, size in sorted(pkg_sizes.items()):
        if size <= threshold_bytes:
            if pkg_binary.get(label):
                binary_below_threshold.append(label)
            continue
        mb = size // (1024 * 1024)
        messages.append("WARNING: {} is {}MB — unusually large pip package.".format(label, mb))
        _add_subpath_or_whole(
            suggestions,
            label,
            pkg_path_map[label],
            mb,
            pkg_binary.get(label, False),
            per_file_threshold_bytes,
        )

    if binary_below_threshold:
        messages.append(
            "NOTE: the following binary packages (Root-Is-Purelib: false) are in the squashed"
            " layer. Add them to layer_tier(groups={...}, compression={...}) to promote them"
            " to dedicated, compression-tuned layers:"
        )
        for lbl in sorted(binary_below_threshold):
            pkg_name = _pkg_name_from_label(lbl)
            messages.append(
                '    "{}": "{}",  # binary package — consider compression ["zstd", "1"]'.format(lbl, pkg_name)
            )

    lines = list(messages)
    if suggestions.group_lines or layer_count_comment_lines:
        lines.append("  Suggested additions to layer_tier(groups=...) to promote these out of the squashed layer:")
        lines.append("    groups = {")
        lines.extend(layer_count_comment_lines)
        lines.extend(suggestions.group_lines.values())
        lines.append("    }")
    if suggestions.compression:
        lines.append("  Suggested additions to layer_tier(compression=...) for the packages above")
        lines.append("  (binary files compress poorly; level 1 is fastest):")
        lines.append("    compression = {")
        for label, level in suggestions.compression.items():
            lines.append('        "{}": ["gzip", "{}"],'.format(label, level))
        lines.append("    }")
        lines.append(
            "  Edit the `layer_tier` target your {} label_flag points at (default: {}).".format(
                _LAYER_TIER_TARGET, _DEFAULT_LAYER_TIER_TARGET
            )
        )

    report = "\n".join(lines) if lines else "OK: all package groups within threshold."

    with open(args.output, "w") as fh:
        fh.write(report + "\n")

    if lines:
        print(report, file=sys.stderr)
    if any(line.startswith("ERROR:") for line in lines):
        sys.exit(1)


if __name__ == "__main__":
    main()
