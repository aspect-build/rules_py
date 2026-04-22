"""Helpers para trabajar con AspectPyInfo.

Este módulo reemplaza el shim de compatibilidad con PyInfo de rules_python.
El grafo interno usa exclusivamente AspectPyInfo.
"""

load("//py/private:aspect_py_info.bzl", "AspectPyInfo", "make_aspect_py_info")

def get_py_info(ctx, merge_infos = []):
    """Obtiene información Python de un target.

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

    # Merge con infos adicionales si se proporcionaron
    if merge_infos:
        return make_aspect_py_info(merge_infos, ctx)

    return None

def has_py_info(target):
    """Verifica si un target tiene información Python.

    Args:
        target: Target a verificar

    Returns:
        bool
    """
    if target == None:
        return False

    return AspectPyInfo in target
