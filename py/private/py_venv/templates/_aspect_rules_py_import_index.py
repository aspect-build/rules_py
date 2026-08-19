"""Load wheel and first-party imports from a compact Bazel virtualenv.

The generated TSV records wheel modules (I), wheel metadata (D), original
retained/virtual root order (R), virtual top-level modules (P), and virtual
namespace children (N). Virtual roots never enter sys.path.
"""

from __future__ import annotations

import os
import sys

TYPE_CHECKING = False
if TYPE_CHECKING:
    from collections.abc import Callable, Iterator, Sequence
    from importlib.machinery import ModuleSpec
    from importlib.metadata import Distribution, DistributionFinder
    from pathlib import Path
    from types import ModuleType
    from typing import Any


def install_import_index() -> None:
    """Resolve indexed imports without projecting packages or expanding sys.path."""
    site_packages = os.path.dirname(__file__)
    index_path = os.path.join(site_packages, ".aspect_rules_py_import_index")

    for finder in sys.meta_path:
        if getattr(finder, "_aspect_rules_py_import_index", None) == index_path:
            return

    path_finder = next(
        finder
        for finder in sys.meta_path
        if getattr(finder, "__name__", None) == "PathFinder"
    )
    initial_path_hooks = tuple(sys.path_hooks)
    indexed_roots = {}
    indexed_distributions = {}
    indexed_metadata_text = {}
    ordered_import_roots = []
    retained_import_roots = {}
    indexed_first_party = {}
    indexed_namespace_portions = {}

    def normalize_distribution_name(name: str) -> str:
        normalized = name.lower().replace("-", "_").replace(".", "_")
        while "__" in normalized:
            normalized = normalized.replace("__", "_")
        return normalized

    with open(index_path, encoding="utf-8") as index_file:
        for line in index_file:
            kind, name, roots = line.rstrip("\r\n").split("\t", 2)
            if kind == "I":
                indexed_roots[name] = roots
            elif kind == "D" and name.endswith((".dist-info", ".egg-info")):
                stem = name.rsplit(".", 1)[0]
                normalized_name = normalize_distribution_name(stem.partition("-")[0])
                record = name + "\t" + roots
                indexed_distributions.setdefault(normalized_name, []).append(record)
            elif kind == "R" and name in {"K", "F"} and "\t" not in roots:
                if name == "K":
                    retained_import_roots[len(ordered_import_roots)] = os.path.normpath(
                        os.path.join(site_packages, roots)
                    )
                ordered_import_roots.append(roots)
            elif kind in {"P", "N"} and ("." in name) == (kind == "N"):
                indexed_first_party[name] = tuple(map(int, roots.split("\t")))
            else:
                raise ValueError(f"Invalid Python import index record in {index_path}")

    stdlib_module_names = getattr(sys, "stdlib_module_names", ())

    def indexed_path_distribution(
        distribution_type: type[Distribution],
        metadata_path: Path,
        ref: Callable[[Distribution], Callable[[], Distribution | None]],
    ) -> Distribution:
        distribution = distribution_type(metadata_path)
        original_read_text = distribution_type.read_text
        canonical_path = os.path.normcase(os.path.abspath(os.fspath(metadata_path)))
        distribution_reference = ref(distribution)

        def cached_read_text(filename: str) -> str | None:
            instance = distribution_reference()
            if instance is None:
                raise ReferenceError("Indexed wheel distribution no longer exists")
            if filename not in (
                "entry_points.txt",
                "METADATA",
                "PKG-INFO",
            ):
                return original_read_text(instance, filename)

            cache_key = (canonical_path, filename)
            try:
                return indexed_metadata_text[cache_key]
            except KeyError:
                # Indexed wheel runfiles are immutable, including absent files.
                text = original_read_text(instance, filename)
                indexed_metadata_text[cache_key] = text
                return text

        # Preserve the concrete type without an instance/bound-method reference cycle.
        distribution.read_text = cached_read_text
        return distribution

    def distribution_records() -> Iterator[str]:
        for records in indexed_distributions.values():
            yield from records

    def register_pkg_resources(module: ModuleType) -> None:
        for entry in distribution_records():
            metadata_directory, _, relative_root = entry.partition("\t")
            wheel_root = os.path.normpath(os.path.join(site_packages, relative_root))
            metadata_path = os.path.join(wheel_root, metadata_directory)
            metadata = module.PathMetadata(wheel_root, metadata_path)
            distribution = module.Distribution.from_location(
                site_packages,
                metadata_directory,
                metadata,
            )
            module.working_set.add(distribution, entry=site_packages, insert=False)
            # Set the real location after activation to keep it off sys.path.
            distribution.location = wheel_root

    def register_pkgutil(module: ModuleType) -> None:
        original_extend_path = module.extend_path

        def extend_path(path: list[str], name: str) -> list[str]:
            path = original_extend_path(path, name)
            if not isinstance(path, list):
                return path
            package = name.replace(".", os.sep)
            for position in indexed_first_party.get(name, ()):
                root = os.path.join(site_packages, ordered_import_roots[position])
                portion = os.path.normpath(os.path.join(root, package))
                if portion not in path and os.path.isdir(portion):
                    path.append(portion)
            return path

        module.extend_path = extend_path

    class _IndexedImportFinder:
        _aspect_rules_py_import_index = index_path

        def _refresh_namespace(
            self, namespace: str, parent_paths: Sequence[str]
        ) -> ModuleSpec | None:
            parent_name, separator, _ = namespace.rpartition(".")
            if not separator:
                return self.find_spec(namespace)
            parent = sys.modules.get(parent_name)
            current_paths = getattr(parent, "__path__", None)
            if current_paths is not None:
                spec = self.find_spec(namespace, current_paths)
                if spec is not None:
                    return spec
            return path_finder.find_spec(namespace, parent_paths)

        def _resolve_spec(
            self, fullname: str, search_paths: Sequence[str], target: ModuleType | None
        ) -> ModuleSpec | None:
            spec = path_finder.find_spec(fullname, search_paths, target)
            if spec is not None and spec.loader is None:
                namespace_paths = spec.submodule_search_locations
                if hasattr(namespace_paths, "_path_finder"):
                    namespace_paths._path_finder = self._refresh_namespace
            return spec

        def find_spec(
            self,
            fullname: str,
            path: Sequence[str] | None = None,
            target: ModuleType | None = None,
        ) -> ModuleSpec | None:
            # Namespace pruning requires the original parent and import hooks.
            if path is not None:
                child_positions = indexed_first_party.get(fullname)
                if child_positions is None or "." not in fullname:
                    return None
                if tuple(sys.path_hooks) != initial_path_hooks:
                    return None

                try:
                    if sys.meta_path[sys.meta_path.index(self) + 1] is not path_finder:
                        return None
                except (ValueError, IndexError):
                    return None

                parent_name, _, _ = fullname.rpartition(".")
                parent = sys.modules.get(parent_name)
                if getattr(parent, "__path__", None) is not path or not hasattr(
                    path, "_path_finder"
                ):
                    return None

                parent_positions = indexed_first_party.get(parent_name)
                known_portions = indexed_namespace_portions.get(parent_name)
                if known_portions is None:
                    parent_directory = parent_name.replace(".", os.sep)
                    known_portions = {
                        os.path.normpath(
                            os.path.join(
                                site_packages,
                                ordered_import_roots[position],
                                parent_directory,
                            )
                        ): position
                        for position in parent_positions
                    }
                    indexed_namespace_portions[parent_name] = known_portions

                child_owners = frozenset(child_positions)
                search_paths = []
                removed_portion = False
                # Prune only indexed portions; preserve physical and custom importers.
                for portion in path:
                    owner = known_portions.get(portion)
                    if owner is None or owner in child_owners:
                        search_paths.append(portion)
                        continue
                    importer = sys.path_importer_cache.get(portion)
                    if importer is not None and type(importer).__name__ != "FileFinder":
                        search_paths.append(portion)
                        continue
                    removed_portion = True

                if not removed_portion:
                    return None

                return self._resolve_spec(fullname, search_paths, target)

            if "." in fullname or (
                fullname in stdlib_module_names and fullname != "pkgutil"
            ):
                return None

            roots = indexed_roots.get(fullname)
            first_party_positions = indexed_first_party.get(fullname)
            bridge = fullname if fullname == "pkgutil" else None
            if indexed_distributions and fullname in {
                "pkg_resources",
                "importlib_metadata",
            }:
                bridge = fullname
            if roots is None and first_party_positions is None:
                if bridge is None:
                    return None
                search_paths = sys.path
            else:
                try:
                    site_packages_position = sys.path.index(site_packages)
                except ValueError:
                    return None

                search_paths = list(sys.path)
                if first_party_positions is not None:
                    live_retained_roots = []
                    for position, root in retained_import_roots.items():
                        try:
                            path_position = search_paths.index(root)
                        except ValueError:
                            continue
                        live_retained_roots.append((position, path_position))

                    insertion_groups = {}
                    for position in first_party_positions:
                        relative_root = ordered_import_roots[position]
                        virtual_root = os.path.normpath(
                            os.path.join(site_packages, relative_root)
                        )
                        if virtual_root in search_paths:
                            continue

                        # Restore this import's root order without mutating sys.path.
                        insert_at = site_packages_position + 1
                        for root_position, path_position in live_retained_roots:
                            if root_position > position:
                                insert_at = path_position
                                break
                            insert_at = path_position + 1
                        insertion_groups.setdefault(insert_at, []).append(virtual_root)

                    for insert_at in sorted(insertion_groups, reverse=True):
                        search_paths[insert_at:insert_at] = insertion_groups[insert_at]

                if roots is not None:
                    search_paths[
                        site_packages_position + 1 : site_packages_position + 1
                    ] = (
                        os.path.normpath(os.path.join(site_packages, root))
                        for root in roots.split("\t")
                    )
            spec = self._resolve_spec(fullname, search_paths, target)
            if bridge is not None and spec is not None and spec.loader is not None:
                original_exec_module = spec.loader.exec_module

                def exec_module(module: ModuleType) -> None:
                    original_exec_module(module)
                    # setuptools and the backport maintain separate metadata registries.
                    if bridge == "pkgutil":
                        register_pkgutil(module)
                    elif bridge == "pkg_resources":
                        register_pkg_resources(module)
                    else:
                        register_importlib_metadata(module)

                spec.loader.exec_module = exec_module
            return spec

        def iter_modules(self, prefix: str = "") -> Iterator[tuple[str, bool]]:
            for fullname in {**indexed_roots, **indexed_first_party}:
                if "." in fullname:
                    continue
                spec = self.find_spec(fullname)
                if spec is not None:
                    yield prefix + fullname, spec.submodule_search_locations is not None

    sys.meta_path.insert(sys.meta_path.index(path_finder), _IndexedImportFinder())

    pkgutil_module = sys.modules.get("pkgutil")
    if pkgutil_module is not None:
        register_pkgutil(pkgutil_module)

    if indexed_distributions:

        def install_distribution_resolver(
            finder: Any, metadata_module: ModuleType | None = None
        ) -> None:
            original_find_distributions = finder.find_distributions
            site_key = os.path.normcase(os.path.abspath(site_packages))

            def find_distributions(
                context: DistributionFinder.Context | None = None,
            ) -> Iterator[Distribution]:
                requested_name = getattr(context, "name", None)
                if requested_name:
                    requested = indexed_distributions.get(
                        normalize_distribution_name(requested_name)
                    )
                    if requested is None:
                        yield from original_find_distributions(context)
                        return
                    entries = requested
                else:
                    entries = distribution_records()

                search_paths = list(getattr(context, "path", sys.path))
                site_packages_position = next(
                    (
                        position
                        for position, path in enumerate(search_paths)
                        if os.path.normcase(os.path.abspath(os.fspath(path)))
                        == site_key
                    ),
                    None,
                )
                if site_packages_position is None:
                    if context is None:
                        yield from original_find_distributions()
                    else:
                        yield from original_find_distributions(context)
                    return

                if metadata_module is None:
                    from importlib.metadata import DistributionFinder, PathDistribution
                else:
                    DistributionFinder = metadata_module.DistributionFinder
                    PathDistribution = metadata_module.PathDistribution
                from pathlib import Path
                from weakref import ref

                context_values = {} if context is None else vars(context).copy()
                # Insert indexed metadata at site-packages' original sys.path position.
                context_values["path"] = search_paths[: site_packages_position + 1]
                yield from original_find_distributions(
                    DistributionFinder.Context(**context_values)
                )

                for entry in entries:
                    metadata_directory, _, relative_root = entry.partition("\t")
                    wheel_root = os.path.normpath(
                        os.path.join(site_packages, relative_root)
                    )
                    yield indexed_path_distribution(
                        PathDistribution,
                        Path(wheel_root) / metadata_directory,
                        ref,
                    )

                trailing_paths = search_paths[site_packages_position + 1 :]
                if trailing_paths:
                    context_values["path"] = trailing_paths
                    yield from original_find_distributions(
                        DistributionFinder.Context(**context_values)
                    )

            if isinstance(finder, type):
                finder.find_distributions = staticmethod(find_distributions)
            else:
                finder.find_distributions = find_distributions

        def register_importlib_metadata(module: ModuleType) -> None:
            # The backport replaces PathFinder with its own metadata resolver.
            metadata_finder_type = getattr(module, "MetadataPathFinder", None)
            if metadata_finder_type is None:
                return
            metadata_finder = next(
                (
                    finder
                    for finder in sys.meta_path
                    if type(finder) is metadata_finder_type
                ),
                None,
            )
            if metadata_finder is not None:
                install_distribution_resolver(metadata_finder, module)

        importlib_metadata = sys.modules.get("importlib_metadata")
        if hasattr(importlib_metadata, "MetadataPathFinder"):
            register_importlib_metadata(importlib_metadata)
        else:
            install_distribution_resolver(path_finder)

    pkg_resources = sys.modules.get("pkg_resources")
    if hasattr(pkg_resources, "working_set"):
        register_pkg_resources(pkg_resources)


install_import_index()
