import importlib
import importlib.machinery
import importlib.util
import os
import sys

_path_cache = {}
_sys_path_cache_key = None
_top_level_roots_cache = {}
_unindexed_sys_path_roots = ()
_path_finder = importlib.machinery.PathFinder
_module_suffixes = tuple(
    importlib.machinery.EXTENSION_SUFFIXES
    + importlib.machinery.SOURCE_SUFFIXES
    + importlib.machinery.BYTECODE_SUFFIXES
)
_source_suffixes = tuple(importlib.machinery.SOURCE_SUFFIXES)


def _clear_path_caches():
    global _path_cache, _sys_path_cache_key, _top_level_roots_cache, _unindexed_sys_path_roots
    _path_cache = {}
    _sys_path_cache_key = None
    _top_level_roots_cache = {}
    _unindexed_sys_path_roots = ()


def _add_top_level_root(top_level_roots, name, root):
    if not name or name == "__init__":
        return
    roots = top_level_roots.get(name)
    if roots is None:
        top_level_roots[name] = [root]
    elif not roots or roots[-1] != root:
        roots.append(root)


def _module_name_from_file(filename):
    for suffix in _module_suffixes:
        if filename.endswith(suffix):
            return filename[:-len(suffix)]
    return None


def _scan_root(top_level_roots, root):
    scan_root = os.getcwd() if root == "" else root
    with os.scandir(scan_root) as entries:
        for entry in entries:
            name = entry.name
            if not name or name[0] == "." or name == "__pycache__":
                continue
            try:
                if entry.is_dir():
                    _add_top_level_root(top_level_roots, name, root)
                    continue
            except OSError:
                continue
            module_name = _module_name_from_file(name)
            if module_name is not None:
                _add_top_level_root(top_level_roots, module_name, root)


def _is_cwd_sensitive_root(root):
    return root == "" or not os.path.isabs(root)


def _current_working_directory():
    try:
        return os.getcwd()
    except FileNotFoundError:
        return None


def _cache_key_for_sys_path(sys_path_key):
    if not any(_is_cwd_sensitive_root(root) for root in sys_path_key):
        return sys_path_key
    return (sys_path_key, _current_working_directory())


def _ensure_path_caches():
    global _path_cache, _sys_path_cache_key, _top_level_roots_cache, _unindexed_sys_path_roots
    sys_path_key = tuple(sys.path)
    cache_key = _cache_key_for_sys_path(sys_path_key)
    if cache_key == _sys_path_cache_key:
        return sys_path_key

    top_level_roots = {}
    unindexed_roots = []
    for root in sys_path_key:
        try:
            _scan_root(top_level_roots, root)
        except (FileNotFoundError, NotADirectoryError, PermissionError, OSError):
            unindexed_roots.append(root)

    _path_cache = {}
    _sys_path_cache_key = cache_key
    _top_level_roots_cache = {
        name: tuple(roots) for name, roots in top_level_roots.items()
    }
    _unindexed_sys_path_roots = tuple(unindexed_roots)
    return sys_path_key


def _search_roots_for_top(top_name):
    sys_path_key = _ensure_path_caches()
    indexed_roots = _top_level_roots_cache.get(top_name, ())
    if not indexed_roots:
        return _unindexed_sys_path_roots
    if not _unindexed_sys_path_roots:
        return indexed_roots

    indexed = set(indexed_roots)
    unindexed = set(_unindexed_sys_path_roots)
    return tuple(root for root in sys_path_key if root in indexed or root in unindexed)


def _merge_parent_path(parent_name, path):
    _ensure_path_caches()
    path_tuple = tuple(path)
    key = (parent_name, path_tuple)
    cached = _path_cache.get(key)
    if cached is not None:
        return cached

    top_name = parent_name.partition('.')[0]
    indexed_roots = _top_level_roots_cache.get(top_name)
    if not indexed_roots:
        _path_cache[key] = path_tuple
        return path_tuple

    parent_rel = parent_name.replace('.', os.sep)
    merged_path = list(path_tuple)
    seen = set(merged_path)
    for root in indexed_roots:
        candidate = os.path.join(root, parent_rel)
        if os.path.isdir(candidate) and candidate not in seen:
            merged_path.append(candidate)
            seen.add(candidate)

    merged_path = tuple(merged_path)
    _path_cache[key] = merged_path
    return merged_path


def _runfiles_source_path(origin):
    if (
        not origin
        or not origin.endswith(_source_suffixes)
        or ".runfiles" + os.sep not in origin
    ):
        return None

    source_path = os.path.realpath(origin)
    if source_path == origin:
        return None
    return source_path


def _rewrite_runfiles_source_spec(spec):
    origin = getattr(spec, 'origin', None)
    source_path = _runfiles_source_path(origin)
    if source_path is None:
        return spec

    # Keep spec.origin on the runfiles path so module.__file__ semantics do not change.
    try:
        spec.cached = importlib.util.cache_from_source(source_path)
    except (NotImplementedError, ValueError):
        pass

    loader = getattr(spec, 'loader', None)
    loader_path = getattr(loader, 'path', None)
    if loader_path is not None and os.path.realpath(loader_path) == source_path:
        loader.path = source_path

    return spec


def _merge_spec_search_locations(fullname, spec):
    spec = _rewrite_runfiles_source_spec(spec)
    locations = getattr(spec, 'submodule_search_locations', None)
    if locations is None:
        return spec

    path_tuple = tuple(locations)
    merged_path = _merge_parent_path(fullname, path_tuple)
    if len(merged_path) != len(path_tuple):
        spec.submodule_search_locations = list(merged_path)
    return spec


if not getattr(_path_finder, '_aspect_static_pth_import_hook', False):
    _original_find_spec = _path_finder.find_spec
    _original_invalidate_caches = _path_finder.invalidate_caches

    def _aspect_static_pth_find_spec(cls, fullname, path=None, target=None):
        if path is None:
            top_name = fullname.partition('.')[0]
            search_roots = _search_roots_for_top(top_name)
            if search_roots:
                spec = _original_find_spec(fullname, list(search_roots), target)
                if spec is not None:
                    return _merge_spec_search_locations(fullname, spec)
            return None

        spec = _original_find_spec(fullname, path, target)
        if spec is not None:
            return _merge_spec_search_locations(fullname, spec)
        if '.' not in fullname:
            return None

        parent_name = fullname.rpartition('.')[0]
        path_tuple = tuple(path)
        merged_path = _merge_parent_path(parent_name, path_tuple)
        if len(merged_path) == len(path_tuple):
            return None

        parent = sys.modules.get(parent_name)
        if parent is not None and hasattr(parent, '__path__'):
            parent.__path__ = list(merged_path)
        return _original_find_spec(fullname, list(merged_path), target)

    def _aspect_static_pth_invalidate_caches(cls):
        _clear_path_caches()
        return _original_invalidate_caches()

    _path_finder.find_spec = classmethod(_aspect_static_pth_find_spec)
    _path_finder.invalidate_caches = classmethod(_aspect_static_pth_invalidate_caches)
    _path_finder._aspect_static_pth_import_hook = True
