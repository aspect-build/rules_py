"""Strict C/C++ driver matching for private PEP 517 wheel actions."""

_COMPILER_PAIRS = [
    ("clang", "clang++"),
    ("gcc", "g++"),
]

def cxx_driver_path(compiler_path, available_paths):
    """Return the declared C++ companion for a recognized C driver, if any."""
    basename = compiler_path.split("/")[-1]
    for cc_basename, cxx_basename in _COMPILER_PAIRS:
        if basename == cc_basename:
            suffix = ""
        elif basename.startswith(cc_basename + "-") and basename[len(cc_basename) + 1:].isdigit():
            suffix = basename[len(cc_basename):]
        else:
            continue

        dirname_index = compiler_path.rfind("/")
        cxx_path = cxx_basename + suffix
        if dirname_index != -1:
            cxx_path = compiler_path[:dirname_index] + "/" + cxx_path
        return cxx_path if cxx_path in available_paths else compiler_path
    return compiler_path
