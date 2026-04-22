"""AspectPyInfo provider - información Python independiente para el grafo de build.

Ubicación: bazel/rules_py/py/private/aspect_py_info.bzl
"""

AspectPyInfo = provider(
    doc = """
    Provider que encapsula información sobre artefactos Python para propagación
    en el grafo de dependencias de Bazel.

    Este provider encapsula información Python para propagación en Bazel y agrega soporte para:
    - Type stubs (.pyi files)
    - Metadatos de resolución UV
    - Información de compatibilidad de Python
    - Runfiles estructurados
    """,
    fields = {
        "imports": """
            Depset[string]: Directorios a agregar a PYTHONPATH.

            Los paths son relativos al workspace root y usan forward slashes.
            Ejemplo: ["my_package", "external/other_repo/src"]
            Orden: preorder para asegurar que los imports del entrypoint tengan prioridad.
            Esto permite shadowing: el py_binary puede sobrescribir módulos de sus dependencias.
        """,
        "transitive_sources": """
            Depset[File]: Todos los archivos .py transitivos necesarios.

            Incluye sources directos y de todas las dependencias transitivas.
            Orden: default (no requiere ordenamiento especial para archivos).
        """,
        "type_stubs": """
            Depset[File]: Archivos .pyi para type checking.

            Estos archivos no son necesarios en runtime pero son esenciales
            para herramientas de análisis estático como mypy, pyright.
            Se propagan transitivamente para permitir type checking completo.
        """,
        "transitive_type_stubs": """
            Depset[File]: Todos los archivos .pyi transitivos.

            Similar a transitive_sources pero para type stubs.
        """,
        "runfiles": """
            Runfiles: Runfiles necesarios para ejecutar este target.

            Incluye archivos de datos, bibliotecas compartidas, y otros
            recursos necesarios en tiempo de ejecución.
        """,
        "default_runfiles": """
            Runfiles: Alias legado de runfiles para compatibilidad.
        """,
        "has_py2_only_sources": """
            bool: Indica si hay código Python 2-only en el árbol transitivo.

            Siempre False para código moderno. Se mantiene para compatibilidad.
        """,
        "has_py3_only_sources": """
            bool: Indica si hay código Python 3-only en el árbol transitivo.

            Generalmente True para código moderno.
        """,
        "uses_shared_libraries": """
            bool: Indica si se usan extensiones C/bibliotecas compartidas.

            True si el árbol transitivo incluye archivos .so, .dll, .dylib.
        """,
        "uv_metadata": """
            struct | None: Metadatos específicos del ecosistema UV.

            Contiene:
            - package_name: Nombre del paquete (str)
            - package_version: Versión del paquete (str)
            - requirements_hash: Hash de los requisitos (str)
            - lockfile_entry: Entrada del uv.lock (str)
        """,
        "transitive_uv_hashes": """
            Depset[string]: Hashes de los lockfiles UV transitivos.

            Permite detectar colisiones de versiones en el punto final (py_binary).
            Si len(transitive_uv_hashes.to_list()) > 1, hay inconsistencias.
        """,
        "_transitive_debug_info": """
            struct: Información interna para debugging.

            Contiene:
            - original_targets: Labels que contribuyeron a este provider
            - creation_path: Stack de creación (en builds debug)
        """,
    },
)

AspectPyVirtualInfo = provider(
    doc = """
    Provider para dependencias virtuales no resueltas.

    Representa requisitos de paquetes que deben ser satisfechos
    sin especificar una versión concreta.
    """,
    fields = {
        "dependencies": """
            Depset[string]: Nombres de paquetes virtuales requeridos.
            Ejemplo: ["django", "requests"]
        """,
        "resolutions": """
            Depset[struct]: Mapeos de resolución virtual -> target.

            Cada struct tiene:
            - virtual: string, nombre del paquete virtual
            - target: Label, target que proporciona la implementación
        """,
        "uv_lock_data": """
            struct | None: Datos del uv.lock para resolución.
        """,
    },
)

AspectPyWheelInfo = provider(
    doc = """
    Provider para información de wheels Python.
    """,
    fields = {
        "files": """
            Depset[File]: Todos los archivos del wheel incluyendo dependencias.
        """,
        "runfiles": """
            Runfiles: Runfiles del wheel.
        """,
        "wheel_metadata": """
            struct: Metadatos del wheel.

            Contiene:
            - name: Nombre del paquete
            - version: Versión
            - python_tag: Tag de Python (e.g., "py3", "cp311")
            - abi_tag: Tag de ABI (e.g., "none", "abi3")
            - platform_tag: Tag de plataforma
        """,
    },
)

AspectPyTypeCheckInfo = provider(
    doc = """
    Provider para configuración de type checking.
    """,
    fields = {
        "pyi_sources": """
            Depset[File]: Archivos .pyi para type checking.
        """,
        "type_config": """
            struct | None: Configuración de type checking.

            Contiene:
            - python_version: Versión de Python objetivo
            - strict_mode: Bool para modo estricto
            - extra_paths: Paths adicionales
        """,
    },
)

def make_aspect_py_info(
        ctx,
        imports = None,
        transitive_sources = None,
        type_stubs = None,
        transitive_type_stubs = None,
        runfiles = None,
        has_py2_only_sources = False,
        has_py3_only_sources = True,
        uses_shared_libraries = False,
        uv_metadata = None,
        transitive_uv_hashes = None,
        debug_info = None):
    """
    Crea una instancia de AspectPyInfo con valores por defecto inteligentes.

    Args:
        ctx: El contexto de la regla
        imports: Lista o depset de paths de import (usar postorder para precedencia)
        transitive_sources: Depset de archivos .py (usar default, no requiere orden)
        type_stubs: Depset de archivos .pyi directos
        transitive_type_stubs: Depset de archivos .pyi transitivos
        runfiles: Runfiles para este target
        has_py2_only_sources: Bool para compatibilidad Py2
        has_py3_only_sources: Bool para indicar Py3-only
        uses_shared_libraries: Bool para extensiones C
        uv_metadata: Struct con metadatos UV
        transitive_uv_hashes: Depset de hashes UV para detección de colisiones
        debug_info: Struct con info de debugging

    Returns:
        AspectPyInfo instance
    """
    if imports == None:
        imports = depset()
    elif type(imports) == "list":
        imports = depset(direct = imports)

    if transitive_sources == None:
        transitive_sources = depset()

    if type_stubs == None:
        type_stubs = depset()
    if transitive_type_stubs == None:
        transitive_type_stubs = type_stubs

    if runfiles == None:
        runfiles = ctx.runfiles()

    if transitive_uv_hashes == None:
        transitive_uv_hashes = depset()

    return AspectPyInfo(
        imports = imports,
        transitive_sources = transitive_sources,
        type_stubs = type_stubs,
        transitive_type_stubs = transitive_type_stubs,
        runfiles = runfiles,
        default_runfiles = runfiles,
        has_py2_only_sources = has_py2_only_sources,
        has_py3_only_sources = has_py3_only_sources,
        uses_shared_libraries = uses_shared_libraries,
        uv_metadata = uv_metadata,
        transitive_uv_hashes = transitive_uv_hashes,
        _transitive_debug_info = debug_info,
    )

def merge_aspect_py_info(infos, ctx = None):
    """
    Múltiples AspectPyInfo en uno solo para propagación transitiva.

    Args:
        infos: Lista de AspectPyInfo a merge
        ctx: Contexto opcional para crear runfiles

    Returns:
        AspectPyInfo mergeado
    """
    if not infos:
        return None

    if len(infos) == 1:
        return infos[0]

    all_imports = []
    all_sources = []
    all_type_stubs = []
    all_transitive_type_stubs = []
    all_uv_hashes = []
    uses_shared = False

    for info in infos:
        all_imports.append(info.imports)
        all_sources.append(info.transitive_sources)
        all_type_stubs.append(info.type_stubs)
        all_transitive_type_stubs.append(info.transitive_type_stubs)
        all_uv_hashes.append(info.transitive_uv_hashes)
        if info.uses_shared_libraries:
            uses_shared = True

    return AspectPyInfo(
        imports = depset(transitive = all_imports),
        transitive_sources = depset(transitive = all_sources),
        type_stubs = depset(transitive = all_type_stubs),
        transitive_type_stubs = depset(transitive = all_transitive_type_stubs),
        runfiles = ctx.runfiles() if ctx else None,
        default_runfiles = ctx.runfiles() if ctx else None,
        has_py2_only_sources = False,
        has_py3_only_sources = True,
        uses_shared_libraries = uses_shared,
        uv_metadata = None,
        transitive_uv_hashes = depset(transitive = all_uv_hashes),
        _transitive_debug_info = None,
    )
