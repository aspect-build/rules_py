"""Compatibility shim para AspectPyInfo.

Este módulo proporciona getters uniformes sobre AspectPyInfo.
Ya no realiza conversión desde PyInfo de rules_python; el grafo interno
usa exclusivamente AspectPyInfo.
"""

load("//py/private:aspect_py_info.bzl", "AspectPyInfo")

def _target_has_py_info(target):
    """Verifica si un target tiene información Python (AspectPyInfo)."""
    return AspectPyInfo in target

def _get_imports(target):
    """Obtiene imports de un target."""
    if AspectPyInfo in target:
        return target[AspectPyInfo].imports
    return depset()

def _get_transitive_sources(target):
    """Obtiene sources de un target."""
    if AspectPyInfo in target:
        return target[AspectPyInfo].transitive_sources
    return depset()

def _get_has_py2_only_sources(target):
    """Obtiene flag de Py2-only."""
    if AspectPyInfo in target:
        return target[AspectPyInfo].has_py2_only_sources
    return False

def _get_has_py3_only_sources(target):
    """Obtiene flag de Py3-only."""
    if AspectPyInfo in target:
        return target[AspectPyInfo].has_py3_only_sources
    return True

def _get_uses_shared_libraries(target):
    """Obtiene flag de bibliotecas compartidas."""
    if AspectPyInfo in target:
        return target[AspectPyInfo].uses_shared_libraries
    return False

PyInfoShim = struct(
    has_py_info = _target_has_py_info,
    get_imports = _get_imports,
    get_transitive_sources = _get_transitive_sources,
    get_has_py2_only_sources = _get_has_py2_only_sources,
    get_has_py3_only_sources = _get_has_py3_only_sources,
    get_uses_shared_libraries = _get_uses_shared_libraries,
)
