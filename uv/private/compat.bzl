load("@bazel_features//:features.bzl", features = "bazel_features")

# bazel_features generates globals.bzl at repository evaluation time:
# - Bazel 8+: _native_set is the built-in set() constructor (O(1) membership)
# - Bazel 7:  _native_set is None (dict-backed fallback below)
_native_set = features.globals.set

def new_set():
    """Returns an empty set, using native set() on Bazel 8+ or a dict on Bazel 7."""
    if _native_set != None:
        return _native_set()
    return {}

def set_add(s, item):
    """Inserts item into a set produced by new_set()."""
    if _native_set != None:
        s.add(item)
    else:
        s[item] = None
