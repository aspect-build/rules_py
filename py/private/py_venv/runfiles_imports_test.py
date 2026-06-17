from __future__ import annotations

import importlib
import os
import pkgutil
import sys
import tempfile
import unittest
from importlib import metadata as stdlib_metadata
from importlib import resources as importlib_resources
from pathlib import Path, PurePath, PureWindowsPath
from unittest import mock

if sys.version_info < (3, 12):
    import importlib_metadata

    _METADATA_IMPLEMENTATIONS = (stdlib_metadata, importlib_metadata)
else:
    _METADATA_IMPLEMENTATIONS = (stdlib_metadata,)

import runfiles_imports
from runfiles_imports import (
    _install_manifest_groups,
    _manifest_groups,
    _parse_manifest_line,
    _resolve_roots,
)


class RunfilesImportsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)

    def _install_manifest(self, manifest: Path, roots: list[str]) -> None:
        old_path = list(sys.path)
        old_hooks = list(sys.path_hooks)
        old_meta_path = list(sys.meta_path)
        self.addCleanup(sys.path.__setitem__, slice(None), old_path)
        self.addCleanup(sys.path_hooks.__setitem__, slice(None), old_hooks)
        self.addCleanup(sys.meta_path.__setitem__, slice(None), old_meta_path)
        for path in _install_manifest_groups(
            _manifest_groups(str(manifest), roots)
        ).values():
            if path not in sys.path:
                sys.path.append(path)
        importlib.invalidate_caches()

    def _cleanup_module(self, name: str) -> None:
        def cleanup() -> None:
            for module in list(sys.modules):
                if module == name or module.startswith(name + "."):
                    sys.modules.pop(module, None)

        self.addCleanup(cleanup)

    def test_parses_escaped_manifest_line(self) -> None:
        self.assertEqual(
            _parse_manifest_line(r" _main/a\sb /physical/a\nb" + "\n"),
            ("_main/a b", "/physical/a\nb"),
        )

    def test_imports_generated_module_from_regular_package_overlay(self) -> None:
        source = self.root / "source/split_package"
        output = self.root / "output/split_package"
        source.mkdir(parents=True)
        output.mkdir(parents=True)
        (source / "__init__.py").write_text("SOURCE = 1\n")
        (output / "generated.py").write_text("GENERATED = 2\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(
            f"_main/split_package/__init__.py {source / '__init__.py'}\n"
            f"_main/split_package/generated.py {output / 'generated.py'}\n"
        )
        self._cleanup_module("split_package")
        self._install_manifest(manifest, ["_main"])

        package = importlib.import_module("split_package")
        generated = importlib.import_module("split_package.generated")

        self.assertEqual(package.SOURCE, 1)
        self.assertEqual(generated.GENERATED, 2)

    def test_reads_split_regular_package_resources(self) -> None:
        source = self.root / "source/resource_package"
        generated = self.root / "output/resource_package"
        source.mkdir(parents=True)
        (generated / "data").mkdir(parents=True)
        (source / "__init__.py").write_text("")
        (source / "undeclared.txt").write_text("not in the manifest")
        (generated / "generated.py").write_text("VALUE = 4\n")
        (generated / "top-level.txt").write_text("top level\n")
        (generated / "data/message.txt").write_text("generated resource\n")
        (generated / "data/blob.bin").write_bytes(b"\x00manifest\xff")
        manifest = self.root / "MANIFEST"
        manifest.write_text(
            f"_main/resource_package/__init__.py {source / '__init__.py'}\n"
            f"_main/resource_package/generated.py {generated / 'generated.py'}\n"
            f"_main/resource_package/top-level.txt {generated / 'top-level.txt'}\n"
            f"_main/resource_package/data/message.txt "
            f"{generated / 'data/message.txt'}\n"
            f"_main/resource_package/data/blob.bin {generated / 'data/blob.bin'}\n"
        )
        self._cleanup_module("resource_package")
        self._install_manifest(manifest, ["_main"])

        package = importlib.import_module("resource_package")
        generated_module = importlib.import_module("resource_package.generated")
        self.assertEqual(generated_module.VALUE, 4)
        # Python 3.9's files() ignores resource readers. Its legacy reader
        # APIs, and files() in later versions, honor the package loader:
        # https://github.com/python/cpython/blob/v3.9.25/Lib/importlib/resources.py#L145-L150
        # https://github.com/python/cpython/blob/v3.10.19/Lib/importlib/resources/_common.py#L21-L24
        if sys.version_info >= (3, 10):
            resources = importlib_resources.files(package)
            self.assertEqual(
                resources.joinpath(PurePath("data"), PurePath("message.txt")).read_text(
                    encoding="utf-8"
                ),
                "generated resource\n",
            )
            self.assertEqual(
                resources.joinpath("data//./message.txt").read_text(
                    encoding="utf-8"
                ),
                "generated resource\n",
            )
            self.assertEqual(
                resources.joinpath(PureWindowsPath(r"data\message.txt")).read_text(
                    encoding="utf-8"
                ),
                "generated resource\n",
            )
            with self.assertRaises(ValueError):
                resources.joinpath(PureWindowsPath(r"..\secret"))
            with self.assertRaises(ValueError):
                resources.joinpath(PureWindowsPath(r"C:\secret"))
        self.assertEqual(
            importlib_resources.read_binary(package, "top-level.txt"),
            b"top level\n",
        )
        self.assertEqual(
            pkgutil.get_data("resource_package", "data/blob.bin"),
            b"\x00manifest\xff",
        )
        with self.assertRaises(FileNotFoundError):
            pkgutil.get_data("resource_package", "undeclared.txt")

    def test_resources_merge_directory_mapping_and_exact_entry(self) -> None:
        package_dir = self.root / "tree/resource_tree_package"
        package_dir.mkdir(parents=True)
        (package_dir / "__init__.py").write_text("")
        (package_dir / "base.txt").write_text("base\n")
        (package_dir / "override.txt").write_text("stale\n")
        override = self.root / "generated/override.txt"
        override.parent.mkdir()
        override.write_text("generated\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(
            f"_main/resource_tree_package {package_dir}\n"
            f"_main/resource_tree_package/override.txt {override}\n"
        )
        self._cleanup_module("resource_tree_package")
        self._install_manifest(manifest, ["_main"])

        package = importlib.import_module("resource_tree_package")
        if sys.version_info >= (3, 10):
            resources = importlib_resources.files(package)
            self.assertEqual(
                {resource.name for resource in resources.iterdir()},
                {"__init__.py", "base.txt", "override.txt"},
            )
            self.assertEqual(
                resources.joinpath("override.txt").read_text(encoding="utf-8"),
                "generated\n",
            )
        self.assertEqual(
            pkgutil.get_data("resource_tree_package", "override.txt"),
            b"generated\n",
        )

    def test_imports_nested_regular_package_overlay(self) -> None:
        source = self.root / "source/nested_package/child"
        output = self.root / "output/nested_package/child"
        source.mkdir(parents=True)
        output.mkdir(parents=True)
        (source.parent / "__init__.py").write_text("")
        (source / "__init__.py").write_text("")
        (output / "generated.py").write_text("VALUE = 3\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(
            f"_main/nested_package/__init__.py {source.parent / '__init__.py'}\n"
            f"_main/nested_package/child/__init__.py {source / '__init__.py'}\n"
            f"_main/nested_package/child/generated.py {output / 'generated.py'}\n"
        )
        self._cleanup_module("nested_package")
        self._install_manifest(manifest, ["_main"])

        generated = importlib.import_module("nested_package.child.generated")

        self.assertEqual(generated.VALUE, 3)

    def test_imports_namespace_package_overlay(self) -> None:
        source = self.root / "source/namespace_package"
        output = self.root / "output/namespace_package"
        source.mkdir(parents=True)
        output.mkdir(parents=True)
        (source / "source.py").write_text("VALUE = 1\n")
        (output / "generated.py").write_text("VALUE = 2\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(
            f"_main/namespace_package/source.py {source / 'source.py'}\n"
            f"_main/namespace_package/generated.py {output / 'generated.py'}\n"
        )
        self._cleanup_module("namespace_package")
        self._install_manifest(manifest, ["_main"])

        source_module = importlib.import_module("namespace_package.source")
        generated = importlib.import_module("namespace_package.generated")

        self.assertEqual(source_module.VALUE, 1)
        self.assertEqual(generated.VALUE, 2)

    def test_imports_package_from_manifest_directory(self) -> None:
        package = self.root / "tree_package"
        package.mkdir()
        (package / "__init__.py").write_text("")
        (package / "child.py").write_text("VALUE = 'tree'\n")
        exact_child = self.root / "exact_child.py"
        exact_child.write_text("VALUE = 'exact'\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(
            f"_main/tree_package {package}\n"
            f"_main/tree_package/child.py {exact_child}\n"
        )
        self._cleanup_module("tree_package")
        self._install_manifest(manifest, ["_main"])

        child = importlib.import_module("tree_package.child")

        self.assertEqual(child.VALUE, "exact")

    def test_discovers_metadata_from_manifest_directory(self) -> None:
        stale_site_packages = self.root / "stale-site-packages"
        (stale_site_packages / "fixture_dist-1.0.dist-info").mkdir(parents=True)
        site_packages = self.root / "site-packages"
        dist_info = site_packages / "fixture_dist-1.0.dist-info"
        dist_info.mkdir(parents=True)
        (site_packages / "fixture.py").write_text(
            "def value():\n"
            "    return 7\n"
        )
        (dist_info / "METADATA").write_text(
            "Metadata-Version: 2.1\n"
            "Name: fixture-dist\n"
            "Version: 1.0\n"
        )
        (dist_info / "entry_points.txt").write_text(
            "[fixture.group]\n"
            "fixture = fixture:value\n"
        )
        manifest = self.root / "MANIFEST"
        manifest.write_text(f"wheel/site-packages {site_packages}\n")
        self._cleanup_module("fixture")
        old_path = list(sys.path)
        self.addCleanup(sys.path.__setitem__, slice(None), old_path)
        sys.path.insert(0, str(stale_site_packages))
        self._install_manifest(manifest, ["wheel/site-packages"])
        self._install_manifest(manifest, ["wheel/site-packages"])

        loaded = importlib.import_module("fixture")

        self.assertEqual(loaded.value(), 7)
        for metadata in _METADATA_IMPLEMENTATIONS:
            available_entry_points = metadata.entry_points()
            group = (
                available_entry_points.select(group="fixture.group")
                if hasattr(available_entry_points, "select")
                else available_entry_points.get("fixture.group", ())
            )
            matching = [
                entry_point
                for entry_point in group
                if entry_point.name == "fixture"
            ]
            self.assertEqual(metadata.version("fixture-dist"), "1.0")
            self.assertEqual(len(matching), 1)
            self.assertEqual(matching[0].load()(), 7)

        overlay_manifest = self.root / "OVERLAY_MANIFEST"
        overlay_manifest.write_text(
            f"wheel/site-packages/fixture.py {site_packages / 'fixture.py'}\n"
        )
        self._install_manifest(overlay_manifest, ["wheel/site-packages"])
        for metadata in _METADATA_IMPLEMENTATIONS:
            self.assertFalse(
                any(
                    distribution.metadata is not None
                    and distribution.metadata.get("Name") == "fixture-dist"
                    for distribution in metadata.distributions()
                )
            )

        self._install_manifest(manifest, ["wheel/site-packages"])
        empty_manifest = self.root / "EMPTY_MANIFEST"
        empty_manifest.write_text("")
        self._install_manifest(empty_manifest, ["wheel/site-packages"])
        sys.modules.pop("fixture", None)
        with self.assertRaises(ModuleNotFoundError):
            importlib.import_module("fixture")
        for metadata in _METADATA_IMPLEMENTATIONS:
            self.assertFalse(
                any(
                    distribution.metadata is not None
                    and distribution.metadata.get("Name") == "fixture-dist"
                    for distribution in metadata.distributions()
                )
            )

    def test_does_not_extend_third_party_regular_package(self) -> None:
        third_party = self.root / "third_party/collision_package"
        generated = self.root / "output/collision_package"
        third_party.mkdir(parents=True)
        generated.mkdir(parents=True)
        (third_party / "__init__.py").write_text("VALUE = 'third-party'\n")
        (generated / "generated.py").write_text("VALUE = 'first-party'\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(
            f"_main/collision_package/generated.py {generated / 'generated.py'}\n"
        )
        self._cleanup_module("collision_package")
        old_path = list(sys.path)
        self.addCleanup(sys.path.__setitem__, slice(None), old_path)
        sys.path.insert(0, str(third_party.parent))
        self._install_manifest(manifest, ["_main"])

        package = importlib.import_module("collision_package")

        self.assertEqual(package.VALUE, "third-party")
        with self.assertRaises(ModuleNotFoundError):
            importlib.import_module("collision_package.generated")

    def test_initialize_preserves_import_root_order(self) -> None:
        prefix = self.root / "venv"
        fallback = self.root / "runfiles/_main/fallback"
        manifest_root = self.root / "manifest_tree"
        fallback.mkdir(parents=True)
        manifest_root.mkdir()
        (fallback / "ordered.py").write_text("VALUE = 'fallback'\n")
        manifest_module = manifest_root / "ordered.py"
        manifest_module.write_text("VALUE = 'manifest'\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(f"_main/manifest/ordered.py {manifest_module}\n")
        helper = self.root / "runfiles_imports.py"
        helper.with_suffix(".txt").write_text(
            "../runfiles\n_main/fallback\nmanifest-only:_main/manifest\n"
        )
        self._cleanup_module("ordered")
        old_path = list(sys.path)
        old_hooks = list(sys.path_hooks)
        old_meta_path = list(sys.meta_path)
        self.addCleanup(sys.path.__setitem__, slice(None), old_path)
        self.addCleanup(sys.path_hooks.__setitem__, slice(None), old_hooks)
        self.addCleanup(sys.meta_path.__setitem__, slice(None), old_meta_path)

        with (
            mock.patch.object(runfiles_imports, "__file__", str(helper)),
            mock.patch.object(sys, "prefix", str(prefix)),
            mock.patch.dict(
                os.environ,
                {
                    "RUNFILES_MANIFEST_FILE": str(manifest),
                    "RUNFILES_MANIFEST_ONLY": "1",
                },
                clear=True,
            ),
        ):
            runfiles_imports.initialize()

        module = importlib.import_module("ordered")

        self.assertEqual(module.VALUE, "fallback")
        self.assertNotIn(str(manifest_root), sys.path)

    def test_manifest_does_not_expose_undeclared_sibling(self) -> None:
        physical_root = self.root / "workspace"
        physical_root.mkdir()
        declared = physical_root / "declared.py"
        declared.write_text("VALUE = 'declared'\n")
        (physical_root / "undeclared.py").write_text("VALUE = 'undeclared'\n")
        manifest = self.root / "MANIFEST"
        manifest.write_text(f"_main/declared.py {declared}\n")
        self._cleanup_module("undeclared")
        self._install_manifest(manifest, ["_main"])

        with self.assertRaises(ModuleNotFoundError):
            importlib.import_module("undeclared")

    def test_prefers_runfiles_directory(self) -> None:
        runfiles = self.root / "runfiles"
        import_root = runfiles / "_main/pkg"
        import_root.mkdir(parents=True)
        self.assertEqual(
            _resolve_roots(
                ["_main/pkg"],
                "unused",
                environ={"RUNFILES_DIR": str(runfiles)},
            ),
            {"_main/pkg": str(import_root)},
        )

    def test_uses_relative_fallback_without_runfiles_environment(self) -> None:
        prefix = self.root / "venv"
        import_root = self.root / "runfiles/_main/pkg"
        import_root.mkdir(parents=True)
        self.assertEqual(
            _resolve_roots(
                ["_main/pkg"],
                "../runfiles",
                environ={},
                prefix=str(prefix),
            ),
            {"_main/pkg": str(import_root)},
        )


if __name__ == "__main__":
    unittest.main()
