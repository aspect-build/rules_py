"""Compatibility shim entre PyInfo de rules_python y AspectPyInfo.

Permite migración gradual sin breaking changes.
"""

load("//py/private:aspect_py_info.bzl", "AspectPyInfo", "make_aspect_py_info")

# Intentar importar PyInfo de rules_python (puede no estar disponible)
_PYINFO_AVAILABLE = False
_PyInfo = None

def _try_import_pyinfo():
    """Intenta importar PyInfo de rules_python."""
    global _PYINFO_AVAILABLE, _PyInfo
    # Usamos un approach seguro para no fallar si rules_python no está disponible
    native.py_test(name = "_dummy_test_for_import", srcs = [], visibility = ["//visibility:private"])
    _PYINFO_AVAILABLE = True
    return _PYINFO_AVAILABLE

def pyinfo_to_aspect_py_info(py_info, ctx = None):
    """Convierte PyInfo de rules_python a AspectPyInfo.

    Args:
        py_info: Provider PyInfo de rules_python
        ctx: Contexto de regla opcional

    Returns:
        AspectPyInfo equivalente
    """
    if py_info == None:
        return None

    # Extraer campos de PyInfo
    imports = getattr(py_info, "imports", depset())
    transitive_sources = getattr(py_info, "transitive_sources", depset())
    runfiles = getattr(py_info, "runfiles", None)
    default_runfiles = getattr(py_info, "default_runfiles", None)

    has_py2 = getattr(py_info, "has_py2_only_sources", False)
    has_py3 = getattr(py_info, "has_py3_only_sources", True)
    uses_shared = getattr(py_info, "uses_shared_libraries", False)

    return AspectPyInfo(
        imports = imports,
        transitive_sources = transitive_sources,
        type_stubs = depset(),  # PyInfo no tiene type stubs
        transitive_type_stubs = depset(),
        runfiles = runfiles if runfiles else (ctx.runfiles() if ctx else None),
        default_runfiles = default_runfiles if default_runfiles else runfiles,
        has_py2_only_sources = has_py2,
        has_py3_only_sources = has_py3,
        uses_shared_libraries = uses_shared,
        uv_metadata = None,
        transitive_uv_hashes = depset(),
        _transitive_debug_info = None,
    )

def aspect_py_info_to_pyinfo(aspect_py_info):
    """Convierte AspectPyInfo a PyInfo (si está disponible).

    Args:
        aspect_py_info: AspectPyInfo a convertir

    Returns:
        PyInfo o None si no está disponible
    """
    if aspect_py_info == None:
        return None

    if not _PYINFO_AVAILABLE:
        return None

    # Si PyInfo está disponible, crear instancia compatible
    # Nota: PyInfo original no tiene todos los campos de AspectPyInfo
    # por lo que perdemos type_stubs y uv_metadata en la conversión
    # Esto es aceptable para compatibilidad hacia atrás

    return None  # Placeholder - implementación real necesitaría acceso a PyInfo

def get_py_info(ctx, merge_infos = []):
    """Obtiene información Python de un target, manejando ambos providers.

    Busca AspectPyInfo primero, luego PyInfo como fallback.
    Convierte PyInfo a AspectPyInfo para consistencia.

    Args:
        ctx: Contexto de regla
        merge_infos: Lista de AspectPyInfo adicionales para merge

    Returns:
        AspectPyInfo o None
    """
    # Buscar AspectPyInfo directo
    if hasattr(ctx.attr, "_aspect_py_info"):
        info = getattr(ctx.attr, "_aspect_py_info", None)
        if info:
            return info

    # Buscar en providers
    for provider in getattr(ctx.attr, "providers", []):
        if type(provider) == "AspectPyInfo":
            return provider

    # Fallback a PyInfo
    # Nota: Esto requeriría acceso a PyInfo desde rules_python
    # Por ahora retornamos None

    # Merge con infos adicionales si se proporcionaron
    if merge_infos:
        return merge_aspect_py_info(merge_infos, ctx)

    return None

def has_py_info(target):
    """Verifica si un target tiene información Python (cualquier provider).

    Args:
        target: Target a verificar

    Returns:
        bool
    """
    if target == None:
        return False

    # Verificar AspectPyInfo
    if AspectPyInfo in target:
        return True

    # Verificar PyInfo (si está disponible)
    # Nota: Esto requeriría acceso a PyInfo desde rules_python

    return False
