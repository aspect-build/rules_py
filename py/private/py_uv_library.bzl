"""Regla py_uv_library para paquetes instalados por UV."""

load("//py/private:aspect_py_info.bzl", "AspectPyInfo")

def _get_py_info():
    """Obtener PyInfo desde rules_python si está disponible."""
    # Primero intentar rules_python
    if native.repository_name() == "_main" or True:  # Siempre intentar
        native_py_info = native.provider("PyInfo", default = None)
        if native_py_info:
            return native_py_info
    
    # Fallback: crear nuestro propio (no será compatible con rules_python)
    return provider(
        doc = "Provider de Python",
        fields = ["transitive_sources", "imports", "has_py2_only_sources",
                  "has_py3_only_sources", "uses_shared_libraries"],
    )


def _py_uv_library_impl(ctx):
    """
    Implementación de py_uv_library para paquetes de UV.

    Esta regla expone un paquete instalado por UV como una biblioteca
    Bazel con AspectPyInfo completo.
    """
    files = ctx.files.srcs

    transitive_sources = depset(direct = files)

    has_so = any([f.extension in ["so", "dylib", "pyd"] for f in files])

    imports = depset(direct = ctx.attr.imports if ctx.attr.imports else [])

    uv_metadata = struct(
        package_name = ctx.attr.package_name,
        version = ctx.attr.version,
        uv_hash = ctx.attr.uv_hash,
    )

    direct_hashes = depset(direct = [ctx.attr.uv_hash] if ctx.attr.uv_hash else [])

    # Crear PyInfo para compatibilidad con rules_python
    py_info = PyInfo(
        transitive_sources = transitive_sources,
        imports = imports,
        has_py2_only_sources = False,
        has_py3_only_sources = True,
        uses_shared_libraries = has_so,
    )

    return [
        DefaultInfo(files = transitive_sources),
        py_info,
        AspectPyInfo(
            transitive_sources = transitive_sources,
            imports = imports,
            type_stubs = depset(),
            transitive_type_stubs = depset(),
            uses_shared_libraries = has_so,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            runfiles = None,
            default_runfiles = None,
            uv_metadata = uv_metadata,
            transitive_uv_hashes = direct_hashes,
            _transitive_debug_info = None,
        ),
    ]

py_uv_library = rule(
    implementation = _py_uv_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Archivos fuente del paquete (descargados por UV)",
        ),
        "package_name": attr.string(
            mandatory = True,
            doc = "Nombre del paquete en PyPI",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "Versión del paquete",
        ),
        "uv_hash": attr.string(
            mandatory = False,
            doc = "Hash SHA256 del paquete en uv.lock",
        ),
        "imports": attr.string_list(
            default = [],
            doc = "Directorios de imports adicionales",
        ),
        "deps": attr.label_list(
            default = [],
            doc = "Dependencias del paquete",
        ),
    },
    doc = """Regla para exponer paquetes Python instalados por UV.

    Esta regla crea un AspectPyInfo completo para un paquete descargado
    por UV, permitiendo que sea usado en el grafo de build de Cosmos.
    """,
)
