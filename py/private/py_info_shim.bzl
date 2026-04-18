"""Compatibility shim para migración gradual de PyInfo a AspectPyInfo.

ESTRATEGIA DE BORDES (Edge Strategy):
- NO usar como decorador global en cada regla
- Solo convertir en los bordes del grafo (dependencias externas)
- El grafo interno de Cosmos usa exclusivamente AspectPyInfo
"""

load("//py/private:aspect_py_info.bzl", "AspectPyInfo")

def _target_has_py_info(target):
    """Verifica si un target tiene información Python."""
    if AspectPyInfo in target:
        return True
    if hasattr(target, "PyInfo"):
        return True
    return False

def _maybe_convert_from_rules_python(target):
    """
    Convierte PyInfo de rules_python a AspectPyInfo SOLO si es necesario.

    Esta función se llama en los BORDES del grafo, cuando se consume
    un target externo que aún usa PyInfo de rules_python.

    Args:
        target: Target potencialmente con PyInfo de rules_python

    Returns:
        AspectPyInfo | None: El provider convertido o None
    """
    if AspectPyInfo in target:
        # Ya es AspectPyInfo, no convertir
        return target[AspectPyInfo]

    # Nota: En Starlark no podemos importar dinámicamente PyInfo de rules_python
    # sin cargarlo explícitamente. Por ahora, esta función es un placeholder
    # para futura compatibilidad.
    return None

def _get_imports(target):
    """Obtiene imports de un target (funciona con ambos providers)."""
    info = _maybe_convert_from_rules_python(target)
    if info:
        return info.imports
    return depset()

def _get_transitive_sources(target):
    """Obtiene sources de un target (funciona con ambos providers)."""
    info = _maybe_convert_from_rules_python(target)
    if info:
        return info.transitive_sources
    return depset()

def _get_has_py2_only_sources(target):
    """Obtiene flag de Py2-only."""
    info = _maybe_convert_from_rules_python(target)
    if info:
        return info.has_py2_only_sources
    return False

def _get_has_py3_only_sources(target):
    """Obtiene flag de Py3-only."""
    info = _maybe_convert_from_rules_python(target)
    if info:
        return info.has_py3_only_sources
    return True

def _get_uses_shared_libraries(target):
    """Obtiene flag de bibliotecas compartidas."""
    info = _maybe_convert_from_rules_python(target)
    if info:
        return info.uses_shared_libraries
    return False

# API pública del shim - SOLO para uso en bordes del grafo
PyInfoShim = struct(
    # Verificación
    has_py_info = _target_has_py_info,

    # Conversión de bordes (USAR SOLO EN BORDES)
    maybe_convert_from_rules_python = _maybe_convert_from_rules_python,

    # Getters compatibles (para reglas que aún necesitan soportar ambos)
    get_imports = _get_imports,
    get_transitive_sources = _get_transitive_sources,
    get_has_py2_only_sources = _get_has_py2_only_sources,
    get_has_py3_only_sources = _get_has_py3_only_sources,
    get_uses_shared_libraries = _get_uses_shared_libraries,
)
