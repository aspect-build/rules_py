#!/usr/bin/env python3

# A tool for generating Gazelle manifests quickly and easily. Doing this in
# Python for now because it should be adequate and doing it in Rust would likely
# be overkill and take more work.
#
# The strategy is simple.
# - Accept an args file containing one wheel/index group per line
#
# - For each whl file
#   - extract the .dist-info/METADATA` file and use that to grab the package name
#   - enumerate Python and native-extension files to identify possible import modules
#   - strip out `_` prefixed modules and packages
#   - enter each module into a mapping from module name to requirement name
#
# - Write a YAML format manifest file {manifest: {modules_mapping: <mapping>, pip_repository: <hub name>}}

from __future__ import annotations

import argparse
import json
import shlex
import sys
from zipfile import ZipFile
from pathlib import Path
from email.parser import Parser
from io import StringIO
from typing import Iterable, List, Optional, Sequence, Set, Tuple
from collections import defaultdict

from exclude_glob import excluded, parse

def normalize_name(name: str) -> str:
    """normalize a PyPI package name and return a valid bazel label.

    Args:
        name: str, the PyPI package name.

    Returns:
        a normalized name as a string.
    """
    name = name.replace("-", "_").replace(".", "_").lower()
    if "__" not in name:
        return name

    # Handle the edge-case where there are consecutive `-`, `_` or `.` characters,
    # which is a valid Python package name.
    return "_".join([
        part
        for part in name.split("_")
        if part
    ])


def normalize_version(version: str) -> str:
    return "".join(character if character.isalnum() or character == "-" else "_" for character in version)


def extract_package(whl_path: Path) -> Optional[tuple[str, str]]:
    """
    Finds the METADATA file in .dist-info/ and extracts
    the 'Name' and 'Version' fields to determine the locked requirement.

    Args:
        whl_path: Path to the wheel file or filtered wheel index.

    Returns:
        The normalized package name and version, or None on failure.
    """
    try:
        if whl_path.name == "gazelle_index.json":
            index = json.loads(whl_path.read_text(encoding="utf-8"))
            return normalize_name(index["name"]), index.get("version", "")

        with ZipFile(whl_path, 'r') as zf:
            metadata_files = [f for f in zf.namelist() if f.endswith('.dist-info/METADATA')]
            metadata_content = zf.read(metadata_files[0]).decode('utf-8') if metadata_files else None

        if metadata_content is None:
            print(f"Error: METADATA file not found in {whl_path}", file=sys.stderr)
            return None

        # Use email.parser (standard library) to reliably parse RFC 822 headers
        parser = Parser()
        msg = parser.parse(StringIO(metadata_content))

        package_name = msg.get('Name')
        package_version = msg.get('Version')
        if not package_name or not package_version:
            print(f"Warning: 'Name' or 'Version' field missing from METADATA in {whl_path}", file=sys.stderr)
            return None

        return normalize_name(package_name.strip()), normalize_version(package_version.strip())

    except Exception as e:
        print(f"Error reading package metadata from {whl_path}: {e}", file=sys.stderr)
        return None

def conventional_name(path_str: str) -> str:
    p = Path(path_str)
    
    # Strip everything after the first dot in the filename
    base_name = p.name.partition('.')[0]
    
    # If the file is in the current directory, return just the base name
    if str(p.parent) == ".":
        return base_name
    
    # Otherwise, join the parent path with the base name
    return str(p.parent / base_name)

def get_importable_module_name(filepath: str) -> Optional[str]:
    """
    Converts a file path inside the wheel (e.g., 'requests/utils.py') into
    an importable module name (e.g., 'requests.utils').

    Filters out internal modules/packages starting with a single underscore.
    Handles __init__.py files by dropping the '__init__' segment.
    """
    # 1. Strip file extension
    if '.' in filepath:
        filepath = conventional_name(filepath)

    # 2. Split into translated site-packages path segments
    segments = site_packages_segments(filepath)

    # 4. Handle __init__ (remove the segment itself)
    if segments[-1] == '__init__':
        segments.pop()

    if any(it.startswith("_") for it in segments):
        return None

    # 5. Join segments with '.' to form the module name
    module_name = ".".join(segments).replace('-', '_')

    return module_name if module_name else None


def site_packages_segments(filepath: str) -> list[str]:
    segments = filepath.split('/')
    if len(segments) >= 2 and segments[0].endswith(".data") and segments[1] in ("platlib", "purelib"):
        return segments[2:]
    return segments


def identify_modules(whl_path: Path, package_name: str, patterns: Sequence[tuple[str, ...]]) -> dict[str, str]:
    """
    Scans the wheel or filtered wheel index for importable Python and extension files,
    maps them to the package name, and applies filtering rules.

    Args:
        whl_path: Path to the wheel file or filtered wheel index.
        package_name: The name of the requirement (e.g., 'requests').
        patterns: Parsed site-packages-relative exclusion globs.

    Returns:
        A dictionary mapping importable module names to the requirement name.
    """
    module_mapping = {}

    # Normalize package name for use as requirement name (Gazelle convention)
    requirement_name = package_name.lower().replace('-', '_')

    try:
        if whl_path.name == "gazelle_index.json":
            members = json.loads(whl_path.read_text(encoding="utf-8"))["paths"]
        else:
            with ZipFile(whl_path, 'r') as zf:
                members = zf.namelist()

        for member in members:
            # Skip files inside dist-info directories
            if '.dist-info/' in member:
                continue

            # Check for importable file types
            # FIXME: C-extensions are, technically, importable.
            if member.endswith(('.py', '.so', '.dylib', '.pyd')):
                if excluded(site_packages_segments(member), patterns):
                    continue
                module_name = get_importable_module_name(member)
                if module_name and module_name not in module_mapping:
                    module_mapping[module_name] = requirement_name

    except Exception as e:
        print(f"Error identifying modules in {whl_path}: {e}", file=sys.stderr)

    return module_mapping


def write_manifest(module_mapping: dict[str, str],
                   output_path: Path,
                   pip_repository_name: str) -> None:
    """
    Formats the module mapping into a YAML-like string and
    writes it to the specified output path. No pyyaml is used.

    Args:
        module_mapping: The collected module-to-requirement map.
        output_path: Path to write the manifest file.
        pip_repository_name: The name to use for pip_repository in the output.
    """
    # Sort the mapping for stable, readable output
    sorted_mapping = "\n".join(
        f"    {key}: {value}"
        for key, value in sorted(module_mapping.items())
    )

    yaml_content = f"""\
manifest:
  modules_mapping:
{sorted_mapping}
  pip_repository:
    name: {pip_repository_name}
"""

    try:
        with open(output_path, 'w') as f:
            f.write(yaml_content)
        print(f"Successfully wrote Gazelle manifest to: {output_path}")
    except Exception as e:
        print(f"Error writing manifest to {output_path}: {e}", file=sys.stderr)


def find_unique_shallowest_prefixes(all_module_package_pairs: Iterable[Tuple[str, str]]) -> dict[str, str]:
    """
    Identifies the shallowest module prefixes that map uniquely to a given Python package.

    Args:
        all_module_package_pairs: (module_name, package_name) tuples from all wheels.

    Returns:
        A dictionary mapping the unique shallowest module prefixes to their corresponding package names.
    """
    prefix_to_packages: defaultdict[str, Set[str]] = defaultdict(set)

    # 1. Populate prefix_to_packages: map each prefix to the set of packages it belongs to.
    for module_name, package_name in all_module_package_pairs:
        parts = module_name.split('.')
        current_prefix_parts = []
        for part in parts:
            current_prefix_parts.append(part)
            prefix = ".".join(current_prefix_parts)
            prefix_to_packages[prefix].add(package_name)

    final_module_mapping: dict[str, str] = {}

    # Sort prefixes by length, then alphabetically to ensure shallower prefixes are processed first.
    sorted_prefixes = sorted(prefix_to_packages.keys(), key=lambda x: (len(x.split('.')), x))

    for prefix in sorted_prefixes:
        # If this prefix maps to multiple packages, it's not unique, so skip it.
        if len(prefix_to_packages[prefix]) > 1:
            continue

        package_for_this_prefix = next(iter(prefix_to_packages[prefix]))

        # Check if this prefix is already covered by a *shorter* prefix that maps to the *same* package.
        is_covered_by_shallower = False
        for mapped_prefix_in_result, mapped_package_in_result in final_module_mapping.items():
            if prefix.startswith(mapped_prefix_in_result + '.') and mapped_package_in_result == package_for_this_prefix:
                is_covered_by_shallower = True
                break

        if not is_covered_by_shallower:
            final_module_mapping[prefix] = package_for_this_prefix

    return final_module_mapping


def main() -> None:
    """
    Parses arguments, processes wheel files, and generates the final manifest.
    """
    parser = argparse.ArgumentParser(
        description="A tool for generating Gazelle manifests from Python wheel files."
    )

    # Args file containing paths to wheel (.whl) files
    parser.add_argument(
        '--whl_paths_file',
        type=Path,
        required=True,
        help="Path to a file containing tab-separated wheel/index paths, one target per line."
    )

    # Output path for the final Gazelle manifest
    parser.add_argument(
        '--output',
        type=Path,
        default=Path('gazelle_manifest.yaml'),
        help="Path to write the final YAML manifest file."
    )

    # Hub name to use
    parser.add_argument(
        '--hub_name',
    )

    args = parser.parse_args()

    # Read wheel paths
    try:
        whl_groups = []
        for line in args.whl_paths_file.read_text().splitlines():
            group = []
            for p in shlex.split(line)[0].split("\t"):
                p = p.strip()
                if not p:
                    continue
                p = Path(p)
                if p.is_file():
                    group.append(p)
                elif p.is_dir():
                    group.extend(p.glob("*.whl"))
                else:
                    print(f"No wheels found for {p}", file=sys.stderr)
            if group:
                whl_groups.append(group)

    except Exception as e:
        print(f"Error reading wheel paths file {args.whl_paths_file}: {e}", file=sys.stderr)
        sys.exit(1)

    if not whl_groups:
        print("Warning: No wheel paths found in the input file. Generating empty manifest.", file=sys.stderr)

    # 3. Process each wheel file
    all_module_package_pairs = set()
    packages_by_path = {}
    modules_by_path_and_patterns = {}
    for group in whl_groups:
        source_exclusions = {}
        for path in group:
            if path.name != "gazelle_index.json":
                continue
            index = json.loads(path.read_text(encoding="utf-8"))
            if "exclude_glob" in index:
                source_exclusions[(normalize_name(index["name"]), index["version"])] = [
                    parse(pattern)
                    for pattern in index["exclude_glob"]
                ]

        for whl_path in group:
            if not whl_path.exists():
                print(f"Warning: Wheel file not found: {whl_path}. Skipping.", file=sys.stderr)
                continue
            if whl_path.name == "gazelle_index.json":
                index = json.loads(whl_path.read_text(encoding="utf-8"))
                if "exclude_glob" in index:
                    continue

            # Get package name (requirement name)
            if whl_path not in packages_by_path:
                packages_by_path[whl_path] = extract_package(whl_path)
            package = packages_by_path[whl_path]
            if not package:
                continue
            package_name, _ = package

            # Identify importable modules for this package
            patterns = () if whl_path.name == "gazelle_index.json" else tuple(source_exclusions.get(package, []))
            key = (whl_path, patterns)
            if key not in modules_by_path_and_patterns:
                modules_by_path_and_patterns[key] = identify_modules(whl_path, package_name, patterns)
            modules = modules_by_path_and_patterns[key]

            all_module_package_pairs.update(modules.items())

    # Process all_module_package_pairs to find unique shallowest prefixes
    final_module_mapping = find_unique_shallowest_prefixes(all_module_package_pairs)

    # 4. Write the final manifest
    write_manifest(final_module_mapping, args.output, args.hub_name)

if __name__ == '__main__':
    main()
