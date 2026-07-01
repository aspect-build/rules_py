"""Strict C/C++ driver matching for private PEP 517 wheel actions."""

_COMPILER_PAIRS = [
    ("clang", "clang++"),
    ("gcc", "g++"),
]

def compiler_driver_paths(compiler_path, available_paths):
    """Return selected C/C++ paths for a recognized C compiler, or None."""
    basename = compiler_path.split("/")[-1]
    for cc_basename, cxx_basename in _COMPILER_PAIRS:
        suffix = None
        if basename == cc_basename:
            suffix = ""
        elif basename.startswith(cc_basename + "-"):
            version = basename[len(cc_basename) + 1:]
            if version and version.isdigit():
                suffix = "-" + version
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
