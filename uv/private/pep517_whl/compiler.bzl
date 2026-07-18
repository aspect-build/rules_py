"""Strict C/C++ driver matching for private PEP 517 wheel actions."""

_COMPILER_PAIRS = [
    ("clang", "clang++"),
    ("gcc", "g++"),
]

def _cxx_companion_path(compiler_path):
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

        return cxx_path
    return None

def cxx_driver_path(compiler_path, available_paths, allow_declared_fallback):
    """Return the available C++ driver for a configured C compiler or wrapper."""
    cxx_path = _cxx_companion_path(compiler_path)
    if cxx_path:
        # Local C++ toolchains can expose absolute system drivers without
        # declaring them in all_files; their companions share that boundary.
        return cxx_path if cxx_path in available_paths or compiler_path.startswith("/") else compiler_path

    if not allow_declared_fallback:
        return compiler_path

    # Toolchains such as toolchains_llvm expose a wrapper for every compile
    # action and declare the real clang/clang++ pair in a separate directory.
    cxx_drivers = {}
    for path in available_paths:
        companion = _cxx_companion_path(path)
        if companion and companion in available_paths:
            cxx_drivers[companion] = True
    return cxx_drivers.keys()[0] if len(cxx_drivers) == 1 else compiler_path
