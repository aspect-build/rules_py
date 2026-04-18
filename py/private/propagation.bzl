"""Estrategias de propagación de AspectPyInfo en el grafo de build."""

load("//py/private:aspect_py_info.bzl", "AspectPyInfo")
load("//py/private:py_info_shim.bzl", "PyInfoShim")

def collect_deps_info(ctx, deps_attr = "deps", data_attr = "data"):
    """
    Colecta información Python de todas las dependencias.

    Esta es la función central para propagar información a través
    del grafo de build.

    Args:
        ctx: Contexto de la regla
        deps_attr: Nombre del atributo de dependencias
        data_attr: Nombre del atributo de datos

    Returns:
        struct con:
        - aspect_py_infos: Lista de AspectPyInfo de deps
        - runfiles: Runfiles mergeados
        - type_stubs: Depset de type stubs
        - has_py2_only: Bool
        - has_py3_only: Bool
        - uses_shared_libs: Bool
    """
    deps = getattr(ctx.attr, deps_attr, [])
    data = getattr(ctx.attr, data_attr, [])

    aspect_py_infos = []
    runfiles_list = []
    has_py2_only = False
    has_py3_only = False
    uses_shared_libs = False

    # Colectar de dependencias
    for dep in deps:
        if PyInfoShim.has_py_info(dep):
            info = PyInfoShim.maybe_convert_from_rules_python(dep)
            if info:
                aspect_py_infos.append(info)
            has_py2_only = has_py2_only or PyInfoShim.get_has_py2_only_sources(dep)
            has_py3_only = has_py3_only or PyInfoShim.get_has_py3_only_sources(dep)
            uses_shared_libs = uses_shared_libs or PyInfoShim.get_uses_shared_libraries(dep)

        # Agregar runfiles
        if DefaultInfo in dep:
            runfiles_list.append(dep[DefaultInfo].default_runfiles)

    # Colectar de data (solo runfiles)
    for d in data:
        if DefaultInfo in d:
            runfiles_list.append(d[DefaultInfo].default_runfiles)

    # Mergear type stubs
    all_type_stubs = depset(transitive = [
        info.transitive_type_stubs
        for info in aspect_py_infos
    ])

    # Mergear runfiles
    merged_runfiles = ctx.runfiles()
    for rf in runfiles_list:
        if rf:
            merged_runfiles = merged_runfiles.merge(rf)

    return struct(
        aspect_py_infos = aspect_py_infos,
        runfiles = merged_runfiles,
        type_stubs = all_type_stubs,
        has_py2_only_sources = has_py2_only,
        has_py3_only_sources = has_py3_only,
        uses_shared_libraries = uses_shared_libs,
    )

def propagate_through_aspect(target, ctx):
    """
    Propagación a través de aspects.

    Args:
        target: Target que se está analizando
        ctx: Contexto del aspect

    Returns:
        Lista de providers a propagar
    """
    if not PyInfoShim.has_py_info(target):
        return []

    info = PyInfoShim.maybe_convert_from_rules_python(target)
    if not info:
        return []

    # Los aspects pueden transformar o filtrar información
    return [info]

def make_imports_depset_with_deps(ctx, imports = None, extra_imports_depsets = None):
    """
    Crea un depset de imports incluyendo los de dependencias.

    Args:
        ctx: Contexto de la regla
        imports: Lista de imports directos
        extra_imports_depsets: Depsets adicionales de imports

    Returns:
        Depset de imports
    """
    if imports == None:
        imports = []
    if extra_imports_depsets == None:
        extra_imports_depsets = []

    deps = getattr(ctx.attr, "deps", [])

    # Agregar imports de dependencias
    transitive_imports = []
    for dep in deps:
        if PyInfoShim.has_py_info(dep):
            transitive_imports.append(PyInfoShim.get_imports(dep))

    transitive_imports.extend(extra_imports_depsets)

    return depset(
        direct = imports,
        transitive = transitive_imports,
    )

def make_srcs_depset_with_deps(ctx, srcs):
    """
    Crea un depset de sources incluyendo los transitivos de dependencias.

    Args:
        ctx: Contexto de la regla
        srcs: Lista de archivos fuente directos

    Returns:
        Depset de sources
    """
    deps = getattr(ctx.attr, "deps", [])

    transitive_srcs = []
    for dep in deps:
        if PyInfoShim.has_py_info(dep):
            transitive_srcs.append(PyInfoShim.get_transitive_sources(dep))

    return depset(
        direct = srcs,
        transitive = transitive_srcs,
    )
