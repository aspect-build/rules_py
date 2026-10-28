r"""Load Windows extension modules from paths near or over MAX_PATH.

Windows' DLL loader rejects such a path for a DLL with an embedded manifest,
even when long paths are enabled, unless the path has the extended-length
`\\?\` prefix. See https://github.com/python/cpython/issues/126929.
"""

import collections.abc
import importlib.machinery
import ntpath
import sys
import types

# Not MAX_PATH (260) itself: for a DLL with a manifest, the loader also builds
# the path plus `.2.Config`, which must fit in MAX_PATH with its terminating
# NUL, so a path of 251 to 259 characters fails too.
_LONGEST_LOADABLE_PATH = 260 - len(".2.Config") - 1

_EXTENDED_LENGTH_PREFIX = "\\\\?\\"


def loadable_path(path: str) -> str:
    # Windows doesn't normalize a `\\?\` path, so it must be absolute, with only
    # backslashes and no `.` or `..` components. The loader's length limit also
    # applies to the absolute path, not to the path as written.
    absolute_path = ntpath.abspath(path)
    if len(absolute_path) <= _LONGEST_LOADABLE_PATH or absolute_path.startswith(
        _EXTENDED_LENGTH_PREFIX
    ):
        return path
    if absolute_path.startswith("\\\\"):
        return _EXTENDED_LENGTH_PREFIX + "UNC\\" + absolute_path[2:]
    return _EXTENDED_LENGTH_PREFIX + absolute_path


class _LongExtensionPathFinder(importlib.machinery.PathFinder):
    @classmethod
    def find_spec(
        cls,
        fullname: str,
        path: collections.abc.Sequence[str] | None = None,
        target: types.ModuleType | None = None,
    ) -> importlib.machinery.ModuleSpec | None:
        spec = super().find_spec(fullname, path, target)
        if spec is None or not isinstance(
            spec.loader, importlib.machinery.ExtensionFileLoader
        ):
            return spec
        spec.origin = spec.loader.path = loadable_path(spec.loader.path)
        return spec


def install() -> None:
    for index, finder in enumerate(sys.meta_path):
        if finder is importlib.machinery.PathFinder:
            sys.meta_path[index] = _LongExtensionPathFinder
            return
