#!/usr/bin/env python3

# A tool for generating Gazelle manifests quickly and easily. Doing this in
# Python for now because it should be adequate and doing it in Rust would likely
# be overkill and take more work.
#
# The strategy is simple.
# - Accept an args file containing paths to wheel (.whl) files or directories containing .whl files
# - A path to a lockfile
# - A path to a file containing an integrity shasum
#
# - For each whl file
#   - open it with a zip reader, extract the .dist-info/METADATA` file and use that to grab the package name
#   - enumerate `.py` and `.so` files to identify possible import modules
#   - strip out `_` prefixed modules and packages
#   - enter each module into a mapping from module name to requirement name
#
# - Write a YAML format manifest file {manifest: {modules_mapping: <mapping>, pip_repository: <hub name>}, integrity: <integrity>}

import argparse
import sys
from zipfile import ZipFile
from pathlib import Path
from email.parser import Parser
from io import StringIO
from typing import Optional

def normalize_name(name):
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

def extract_package_name(whl_path: Path) -> Optional[str]:
    """
    Opens a .whl file, finds the METADATA file in .dist-info/, and extracts
    the 'Name' field to determine the requirement name.

    Args:
        whl_path: Path to the wheel file.

    Returns:
        The package name (requirement name) as a string, or None on failure.
    """
    try:
        with ZipFile(whl_path, 'r') as zf:
            # Find the METADATA file. It's always in <distribution>-<version>.dist-info/METADATA
            metadata_files = [f for f in zf.namelist() if f.endswith('.dist-info/METADATA')]
            if not metadata_files:
                print(f"Error: METADATA file not found in {whl_path}", file=sys.stderr)
                return None

            # Read the content of the METADATA file
            with zf.open(metadata_files[0]) as f:
                metadata_content = f.read().decode('utf-8')

            # Use email.parser (standard library) to reliably parse RFC 822 headers
            parser = Parser()
            msg = parser.parse(StringIO(metadata_content))

            package_name = msg.get('Name')
            if not package_name:
                print(f"Warning: 'Name' field missing from METADATA in {whl_path}", file=sys.stderr)
                return None

            return normalize_name(package_name.strip())

    except Exception as e:
        print(f"Error reading package name from {whl_path}: {e}", file=sys.stderr)
        return None

def get_importable_module_name(filepath: str) -> Optional[str]:
    """
    Converts a file path inside the wheel (e.g., 'requests/utils.py') into
    an importable module name (e.g., 'requests.utils').

    Filters out internal modules/packages starting with a single underscore.
    Handles __init__.py files by dropping the '__init__' segment.
    """
    # 1. Strip file extension
    if '.' in filepath:
        filepath = filepath.rsplit('.', 1)[0]

    # 2. Split into path segments
    segments = filepath.split('/')

    # 3. Filter out single-underscore prefixed segments (e.g., requests/_internal)
    # Exclude '__init__' from the underscore check
    filtered_segments = [s for s in segments if not (s.startswith('_') and s != '__init__')]

    # If any segment was filtered out, we exclude the entire path
    if len(filtered_segments) != len(segments):
        return None

    # 4. Handle __init__ (remove the segment itself)
    if filtered_segments and filtered_segments[-1] == '__init__':
        filtered_segments.pop()

    if any(it.startswith("_") for it in filtered_segments):
        return None

    # 5. Join segments with '.' to form the module name
    module_name = ".".join(filtered_segments).replace('-', '_')

    return module_name if module_name else None

def identify_modules(whl_path: Path, package_name: str) -> dict[str, str]:
    """
    Scans the wheel for importable Python (.py) and extension (.so) files,
    maps them to the package name, and applies filtering rules.

    Args:
        whl_path: Path to the wheel file.
        package_name: The name of the requirement (e.g., 'requests').

    Returns:
        A dictionary mapping importable module names to the requirement name.
    """
    module_mapping = {}

    # Normalize package name for use as requirement name (Gazelle convention)
    requirement_name = package_name.lower().replace('-', '_')

    try:
        print(f"Indexing {whl_path.name}...", file=sys.stderr)

        with ZipFile(whl_path, 'r') as zf:
            for member in zf.namelist():
                # Skip files inside dist-info, test, or example directories
                if any(p in member for p in ['.dist-info/']):
                    continue

                # Check for importable file types
                # FIXME: C-extensions are, technically, importable.
                if member.endswith(('.py')):
                    module_name = get_importable_module_name(member)
                    if module_name:
                        # Add to mapping
                        if module_name not in module_mapping:
                            module_mapping[module_name] = requirement_name
                        # else: module already found, perhaps via a different path, skip

    except Exception as e:
        print(f"Error identifying modules in {whl_path}: {e}", file=sys.stderr)

    return module_mapping

def write_manifest(module_mapping: dict[str, str],
                   output_path: Path,
                   pip_repository_name: str = "pypi") -> None:
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

# --- Main Logic and Argument Parsing ---

def main():
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
        help="Path to a file containing a list of paths to wheel (.whl) files, one per line."
    )

    # Output path for the final Gazelle manifest
    parser.add_argument(
        '--output',
        type=Path,
        default=Path('gazelle_manifest.yaml'),
        help="Path to write the final YAML manifest file."
    )

    args = parser.parse_args()

    # Read wheel paths
    try:
        whl_paths_raw = args.whl_paths_file.read_text().splitlines()
        whl_paths = []
        for p in whl_paths_raw:
            p = p.strip()
            if p:
                p = Path(p)
                if p.is_file():
                    whl_paths.append(p)
                elif p.is_dir():
                    whl_paths.extend(p.glob("*.whl"))
                else:
                    print(f"No wheels found for {p}", file=sys.stderr)

    except Exception as e:
        print(f"Error reading wheel paths file {args.whl_paths_file}: {e}", file=sys.stderr)
        sys.exit(1)

    if not whl_paths:
        print("Warning: No wheel paths found in the input file. Generating empty manifest.", file=sys.stderr)

    # 3. Process each wheel file
    final_module_mapping = {}
    for whl_path in whl_paths:
        if not whl_path.exists():
            print(f"Warning: Wheel file not found: {whl_path}. Skipping.", file=sys.stderr)
            continue

        # Get package name (requirement name)
        package_name = extract_package_name(whl_path)
        if not package_name:
            continue

        # Identify importable modules for this package
        modules = identify_modules(whl_path, package_name)

        # Merge results into the final map
        final_module_mapping.update(modules)

    # 4. Write the final manifest
    write_manifest(final_module_mapping, args.output)

if __name__ == '__main__':
    main()
