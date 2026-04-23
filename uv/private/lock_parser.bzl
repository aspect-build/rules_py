def parse_uv_lock(content, host_platform = None, wheels_only = True):
    """Parse uv.lock file and select appropriate wheels for the host platform.

    Args:
        content: The content of the uv.lock file
        host_platform: The host platform string (e.g., "aarch64-apple-darwin", "x86_64-apple-darwin")
        wheels_only: If True, only include packages with wheels

    Returns:
        List of package dicts with selected url and sha256 for the host platform
    """
    packages = []
    current_package = None
    in_dependencies = False
    in_wheels = False
    sdist_url = ""
    sdist_sha256 = ""

    available_wheels = []

    lines = content.split("\n")

    for i in range(len(lines)):
        line = lines[i]
        stripped = line.strip()

        if stripped == "[[package]]":
            if current_package:
                selected = _select_wheel(available_wheels, host_platform, sdist_url, sdist_sha256, wheels_only)
                if selected:
                    current_package["url"] = selected["url"]
                    current_package["sha256"] = selected["sha256"]
                packages.append(current_package)

            current_package = {
                "name": "",
                "version": "",
                "url": "",
                "sha256": "",
                "dependencies": [],
            }
            available_wheels = []
            sdist_url = ""
            sdist_sha256 = ""
            in_dependencies = False
            in_wheels = False

        elif current_package and stripped.startswith("name = "):
            current_package["name"] = _extract_string(stripped)

        elif current_package and stripped.startswith("version = "):
            current_package["version"] = _extract_string(stripped)

        elif current_package and stripped.startswith("dependencies = ["):
            in_dependencies = True
            if "]" in stripped:
                deps_str = stripped[stripped.find("[") + 1:stripped.find("]")]
                current_package["dependencies"] = _parse_dependencies(deps_str)
                in_dependencies = False

        elif current_package and in_dependencies and stripped == "]":
            in_dependencies = False

        elif current_package and in_dependencies:
            dep = _extract_dep_name(stripped)
            if dep:
                current_package["dependencies"].append(dep)

        elif current_package and stripped.startswith("sdist = "):
            url, sha256 = _extract_url_and_hash(stripped)
            if url:
                sdist_url = url
            if sha256:
                sdist_sha256 = sha256

        elif current_package and stripped.startswith("wheels = ["):
            in_wheels = True

        elif current_package and in_wheels and stripped.startswith("]"):
            in_wheels = False

        elif current_package and in_wheels and stripped.startswith("{ url = "):
            url, sha256 = _extract_url_and_hash(stripped)
            if url and ".whl" in url and "pypy" not in url.lower():
                available_wheels.append({"url": url, "sha256": sha256})

    if current_package:
        selected = _select_wheel(available_wheels, host_platform, sdist_url, sdist_sha256, wheels_only)
        if selected:
            current_package["url"] = selected["url"]
            current_package["sha256"] = selected["sha256"]
        packages.append(current_package)

    return packages

def _select_wheel(wheels, host_platform, sdist_url, sdist_sha256, wheels_only):
    """Select the best wheel for the host platform.

    Priority:
    1. Exact platform match (e.g., macosx_14_0_arm64 for aarch64-apple-darwin)
    2. Compatible platform match (e.g., macosx_13_0_arm64 works on macOS 14)
    3. Universal wheel (py3-none-any, py2.py3-none-any)
    4. Source distribution (sdist) if wheels_only is False
    """
    if not wheels:
        if not wheels_only and sdist_url:
            return {"url": sdist_url, "sha256": sdist_sha256}
        return None

    platform_patterns = _get_platform_patterns(host_platform)

    for wheel in wheels:
        url = wheel["url"]
        for pattern in platform_patterns.get("exact", []):
            if pattern in url:
                return wheel

    for wheel in wheels:
        url = wheel["url"]
        for pattern in platform_patterns.get("compatible", []):
            if pattern in url:
                return wheel

    for wheel in wheels:
        url = wheel["url"]
        if "py3-none-any" in url or "py2.py3-none-any" in url:
            return wheel

    if not host_platform:
        return wheels[0]

    if not wheels_only and sdist_url:
        return {"url": sdist_url, "sha256": sdist_sha256}

    return None

def _get_platform_patterns(host_platform):
    """Get platform tag patterns for a given host platform.

    Returns dict with 'exact' and 'compatible' patterns.
    """
    if not host_platform:
        return {"exact": [], "compatible": []}

    platform_mappings = {
        "aarch64-apple-darwin": {
            "exact": [
                "macosx_15_0_arm64",
                "macosx_14_0_arm64",
                "macosx_13_0_arm64",
                "macosx_12_0_arm64",
                "macosx_11_0_arm64",
            ],
            "compatible": [
                "macosx_15_0_universal2",
                "macosx_14_0_universal2",
                "macosx_13_0_universal2",
                "macosx_12_0_universal2",
                "macosx_11_0_universal2",
                "macosx_10_15_universal2",
                "macosx_10_14_universal2",
                "macosx_10_13_universal2",
                "macosx_10_12_universal2",
                "macosx_10_11_universal2",
                "macosx_10_10_universal2",
                "macosx_10_9_universal2",
            ],
        },
        "x86_64-apple-darwin": {
            "exact": [
                "macosx_15_0_x86_64",
                "macosx_14_0_x86_64",
                "macosx_13_0_x86_64",
                "macosx_12_0_x86_64",
                "macosx_11_0_x86_64",
                "macosx_10_15_x86_64",
                "macosx_10_14_x86_64",
                "macosx_10_13_x86_64",
                "macosx_10_12_x86_64",
            ],
            "compatible": [
                "macosx_15_0_universal2",
                "macosx_14_0_universal2",
                "macosx_13_0_universal2",
                "macosx_12_0_universal2",
                "macosx_11_0_universal2",
                "macosx_10_15_universal2",
                "macosx_10_14_universal2",
                "macosx_10_13_universal2",
                "macosx_10_12_universal2",
                "macosx_10_11_universal2",
                "macosx_10_10_universal2",
                "macosx_10_9_universal2",
            ],
        },
        "aarch64-unknown-linux-gnu": {
            "exact": [
                "manylinux_2_31_aarch64",
                "manylinux_2_28_aarch64",
                "manylinux_2_24_aarch64",
                "manylinux_2_17_aarch64",
                "manylinux2014_aarch64",
            ],
            "compatible": [],
        },
        "x86_64-unknown-linux-gnu": {
            "exact": [
                "manylinux_2_31_x86_64",
                "manylinux_2_28_x86_64",
                "manylinux_2_24_x86_64",
                "manylinux_2_17_x86_64",
                "manylinux2014_x86_64",
                "manylinux_2_12_x86_64",
                "manylinux2010_x86_64",
                "manylinux_2_5_x86_64",
                "manylinux1_x86_64",
            ],
            "compatible": [],
        },
        "aarch64-unknown-linux-musl": {
            "exact": [
                "musllinux_1_2_aarch64",
                "musllinux_1_1_aarch64",
            ],
            "compatible": [],
        },
        "x86_64-unknown-linux-musl": {
            "exact": [
                "musllinux_1_2_x86_64",
                "musllinux_1_1_x86_64",
            ],
            "compatible": [],
        },
        "x86_64-pc-windows-msvc": {
            "exact": [
                "win_amd64",
            ],
            "compatible": [],
        },
    }

    return platform_mappings.get(host_platform, {"exact": [], "compatible": []})

def _extract_string(line):
    start = line.find('"')
    if start == -1:
        return ""
    end = line.find('"', start + 1)
    if end == -1:
        return ""
    return line[start + 1:end]

def _parse_dependencies(deps_str):
    deps = []
    for part in deps_str.split(","):
        dep = _extract_dep_name(part.strip())
        if dep:
            deps.append(dep)
    return deps

def _extract_dep_name(line):
    if not line or line == "{":
        return None
    if '{ name = "' in line:
        start = line.find('{ name = "') + 10
        end = line.find('"', start)
        return line[start:end]
    return None

def _extract_url_and_hash(line):
    url = ""
    sha256 = ""

    if 'url = "' in line:
        start = line.find('url = "') + 7
        end = line.find('"', start)
        url = line[start:end]

    if 'hash = "sha256:' in line:
        start = line.find('hash = "sha256:') + 15
        end = line.find('"', start)
        sha256 = line[start:end]
    elif 'hash = "' in line:
        start = line.find('hash = "') + 8
        end = line.find('"', start)
        hash_val = line[start:end]
        if hash_val.startswith("sha256:"):
            sha256 = hash_val[7:]

    return url, sha256
