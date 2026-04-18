"""Repository rule for generating Gazelle Python manifest from uv.lock.

This module provides a repository rule that downloads wheels from uv.lock
and inspects them to generate a modules mapping for Gazelle Python.
"""

load(":lock_parser.bzl", "parse_uv_lock")

def _normalize_package_name(name):
    """Normalize package name for comparison."""
    return name.replace("-", "_").replace(".", "_").lower()

_WHEEL_INSPECT_SCRIPT = '''
import json
import zipfile
import sys

def inspect_wheel(whl_path):
    """Inspect a wheel and return module -> package mapping."""
    mapping = {}
    # Extract package name from wheel filename: name-version-... .whl
    # Handle names with hyphens like "django-crontab"
    whl_filename = whl_path.split("/")[-1]
    pkg_name = whl_filename.split("-")[0].lower().replace("-", "_")
    
    with zipfile.ZipFile(whl_path, "r") as zf:
        # Try top_level.txt first
        top_level = None
        for name in zf.namelist():
            if name.endswith("top_level.txt"):
                top_level = name
                break
        
        use_top_level = False
        if top_level:
            content = zf.read(top_level).decode("utf-8").strip()
            if content:
                use_top_level = True
                for line in content.split("\\n"):
                    line = line.strip()
                    if line and not line.startswith("#"):
                        mapping[line] = pkg_name
        
        # Fallback: scan directory structure if top_level.txt missing or empty
        if not use_top_level:
            top_dirs = set()
            for name in zf.namelist():
                parts = name.split("/")
                if len(parts) > 0:
                    top_dir = parts[0]
                    # Skip metadata directories
                    if top_dir.endswith(".dist-info") or top_dir.endswith(".data"):
                        continue
                    # Skip files at root level (like LICENSE, README)
                    if "." in top_dir and not top_dir.startswith("."):
                        continue
                    top_dirs.add(top_dir)
            
            for top_dir in top_dirs:
                mapping[top_dir] = pkg_name
    
    return mapping

if __name__ == "__main__":
    result = {}
    for whl in sys.argv[1:]:
        try:
            result.update(inspect_wheel(whl))
        except Exception as e:
            print(f"Warning: Failed to inspect {whl}: {e}", file=sys.stderr)
    print(json.dumps(result, sort_keys=True))
'''

def _gazelle_python_yaml_repository_impl(ctx):
    """Implementation of the Gazelle manifest repository rule."""
    lock_file = ctx.path(ctx.attr.uv_lock)
    
    if not lock_file.exists:
        fail("uv.lock not found: {}".format(lock_file))
    
    lock_content = ctx.read(lock_file)
    packages = parse_uv_lock(lock_content, wheels_only = False)
    
    cache_dir = ctx.path("_wheel_cache")
    ctx.execute(["mkdir", "-p", str(cache_dir)])
    
    no_wheel_packages = []
    
    downloaded_wheels = []
    for pkg in packages:
        url = pkg.get("url", "")
        pkg_name = pkg.get("name", "")
        
        url_path = url.split("?")[0]
        if not ".whl" in url_path:
            if pkg_name:
                no_wheel_packages.append(pkg_name)
            continue
        
        wheel_name = url.split("/")[-1]
        wheel_path = cache_dir.get_child(wheel_name)
        
        download_result = ctx.download(
            url = url,
            output = str(wheel_path),
            sha256 = pkg.get("sha256", ""),
        )
        
        # ctx.download with sha256 returns a struct with success field
        if hasattr(download_result, "success") and download_result.success and wheel_path.exists:
            downloaded_wheels.append(str(wheel_path))
    
    ctx.file("_inspect.py", _WHEEL_INSPECT_SCRIPT)
    
    mapping = {}
    batch_size = 50
    
    for i in range(0, len(downloaded_wheels), batch_size):
        batch = downloaded_wheels[i:i + batch_size]
        result = ctx.execute(["python3", "_inspect.py"] + batch)
        
        if result.return_code == 0:
            if result.stdout:
                batch_mapping = json.decode(result.stdout)
                mapping.update(batch_mapping)
    
    for pkg_name in no_wheel_packages:
        module_name = pkg_name.replace("-", "_").lower()
        if module_name not in mapping:
            mapping[module_name] = module_name
    
    for imp, pkg in ctx.attr.modules_mapping.items():
        mapping[imp] = pkg
    
    content = """# GENERATED FILE - DO NOT EDIT!
#
# Generated from uv.lock by inspecting {} wheel files

---
manifest:
  pip_repository:
    name: {}
    target_pattern: "@{}//{{name}}:lib"
  modules_mapping:
""".format(len(downloaded_wheels), ctx.attr.hub_name, ctx.attr.hub_name)
    
    for imp_name in sorted(mapping.keys()):
        pkg_name = mapping[imp_name]
        content += "    {}: {}\n".format(imp_name, pkg_name)
    
    ctx.file("gazelle_python.yaml", content)
    ctx.file("BUILD.bazel", 'exports_files(["gazelle_python.yaml"])')
    
    ctx.delete("_wheel_cache")
    ctx.delete("_inspect.py")

gazelle_python_yaml_repository = repository_rule(
    implementation = _gazelle_python_yaml_repository_impl,
    attrs = {
        "uv_lock": attr.label(
            mandatory = True,
            allow_single_file = [".lock"],
            doc = "The uv.lock file to parse",
        ),
        "hub_name": attr.string(
            mandatory = True,
            doc = "Name of the hub repository (for reference)",
        ),
        "modules_mapping": attr.string_dict(
            default = {},
            doc = """Override mappings for import names.
            
            These take priority over auto-detected mappings.
            Example: {"PIL": "pillow", "bs4": "beautifulsoup4"}
            """,
        ),
    },
    doc = """Generate gazelle_python.yaml from uv.lock by inspecting wheels.
    
    This repository rule downloads wheels from the uv.lock file, inspects
them to detect import names, and generates a gazelle_python.yaml manifest.
    """
)

def uv_gazelle_manifest(name, hub, uv_lock = "//:uv.lock", modules_mapping = {}):
    """Generate gazelle_python.yaml manifest from uv.lock.
    
    This macro creates a repository containing gazelle_python.yaml, which maps
    Python import names to package names for Gazelle Python integration.
    
    Args:
        name: Name of the repository to create
        hub: Name of the hub repository (for reference)
        uv_lock: Label to the uv.lock file
        modules_mapping: Optional overrides for cases that can't be auto-detected
        
    Example:
        ```starlark
        uv_gazelle_manifest(
            name = "pystar_gazelle",
            hub = "pystar",
            uv_lock = "//:uv.lock",
            modules_mapping = {
                "PIL": "pillow",
                "bs4": "beautifulsoup4",
            },
        )
        ```
    """
    gazelle_python_yaml_repository(
        name = name,
        uv_lock = uv_lock,
        hub_name = hub,
        modules_mapping = modules_mapping,
    )
