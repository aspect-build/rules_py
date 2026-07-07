"""Strict C/C++ driver matching for private PEP 517 wheel actions."""

_COMPILER_PAIRS = [
    ("clang", "clang++"),
    ("gcc", "g++"),
]

def _driver_suffix(basename, driver_basename):
    if basename == driver_basename:
        return ""
    if not basename.startswith(driver_basename + "-"):
        return None
    version = basename[len(driver_basename) + 1:]
    return "-" + version if version and version.isdigit() else None

def compiler_driver_paths(compiler_path, available_paths):
    """Return selected C/C++ paths for a recognized C compiler, or None."""
    basename = compiler_path.split("/")[-1]
    for cc_basename, cxx_basename in _COMPILER_PAIRS:
        suffix = _driver_suffix(basename, cc_basename)
        if suffix == None:
            continue

        cxx_path = cxx_basename + suffix
        dirname_index = compiler_path.rfind("/")
        if dirname_index != -1:
            cxx_path = compiler_path[:dirname_index] + "/" + cxx_path
        if cxx_path not in available_paths:
            cxx_path = compiler_path
        return struct(cxx = cxx_path)
    return None

def cxx_driver_fallback_path(compiler_path):
    """Return a recognized C++ driver path for same-driver fallback, or None."""
    basename = compiler_path.split("/")[-1]
    for _, cxx_basename in _COMPILER_PAIRS:
        if _driver_suffix(basename, cxx_basename) != None:
            return compiler_path
    return None
