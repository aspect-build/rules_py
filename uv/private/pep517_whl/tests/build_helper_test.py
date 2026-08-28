"""Unit tests for build_helper's pure helpers.

These exist because build_helper.py is import-safe: the CLI body lives
under main(), so the module's functions can be exercised directly. The
import at the top of this file is itself the regression test for that
guard — before it, importing the module ran the build.
"""

import os
import sys
import tempfile
import unittest
from os import makedirs, path

from uv.private.pep517_whl.tools import build_helper


def _make_executable(directory: str, name: str) -> str:
    exe = path.join(directory, name)
    with open(exe, "w") as f:
        f.write("#!/bin/sh\n")
    os.chmod(exe, 0o755)
    return exe


class ImportSafetyTest(unittest.TestCase):
    def test_main_is_exposed_not_executed(self) -> None:
        self.assertTrue(callable(build_helper.main))


class AbsolutizePathTest(unittest.TestCase):
    def test_empty_stays_empty(self) -> None:
        self.assertEqual(build_helper._absolutize_path(""), "")

    def test_absolute_untouched(self) -> None:
        self.assertEqual(build_helper._absolutize_path("/usr/bin/cc"), "/usr/bin/cc")

    def test_relative_resolves_against_cwd(self) -> None:
        self.assertEqual(
            build_helper._absolutize_path("bin/cc"),
            path.join(os.getcwd(), "bin/cc"),
        )


class ResolveCompilerPathTest(unittest.TestCase):
    def test_missing_key_returns_default(self) -> None:
        self.assertEqual(build_helper._resolve_compiler_path({}, "CC", "cc"), "cc")

    def test_empty_value_returns_default(self) -> None:
        self.assertEqual(build_helper._resolve_compiler_path({"CC": ""}, "CC", "cc"), "cc")

    def test_pathful_value_is_absolutized(self) -> None:
        env = {"CC": "external/toolchain/bin/gcc"}
        self.assertEqual(
            build_helper._resolve_compiler_path(env, "CC", "cc"),
            path.join(os.getcwd(), "external/toolchain/bin/gcc"),
        )

    def test_flags_after_the_driver_are_ignored(self) -> None:
        env = {"CC": "/opt/bin/gcc -pthread"}
        self.assertEqual(build_helper._resolve_compiler_path(env, "CC", "cc"), "/opt/bin/gcc")

    def test_bare_name_resolves_on_env_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            exe = _make_executable(tmp, "mycc")
            env = {"CC": "mycc", "PATH": tmp}
            self.assertEqual(build_helper._resolve_compiler_path(env, "CC", "cc"), exe)

    def test_bare_name_not_on_path_passes_through(self) -> None:
        env = {"CC": "no-such-compiler", "PATH": "/nonexistent"}
        self.assertEqual(
            build_helper._resolve_compiler_path(env, "CC", "cc"),
            "no-such-compiler",
        )


class LocalCxxCompanionTest(unittest.TestCase):
    def test_no_current_returns_compiler(self) -> None:
        self.assertEqual(build_helper._local_cxx_companion(None, "/opt/gcc"), "/opt/gcc")

    def test_relative_current_returns_compiler(self) -> None:
        self.assertEqual(build_helper._local_cxx_companion("gcc", "/opt/gcc"), "/opt/gcc")

    def test_gcc_finds_sibling_gxx(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            gcc = _make_executable(tmp, "gcc")
            gxx = _make_executable(tmp, "g++")
            self.assertEqual(build_helper._local_cxx_companion(gcc, gcc), gxx)

    def test_versioned_clang_finds_versioned_companion(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            clang = _make_executable(tmp, "clang-15")
            clangxx = _make_executable(tmp, "clang++-15")
            self.assertEqual(build_helper._local_cxx_companion(clang, clang), clangxx)

    def test_prefixed_cc_finds_prefixed_cxx(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cc = _make_executable(tmp, "aarch64-linux-gnu-gcc")
            cxx = _make_executable(tmp, "aarch64-linux-gnu-g++")
            self.assertEqual(build_helper._local_cxx_companion(cc, cc), cxx)

    def test_missing_companion_returns_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            gcc = _make_executable(tmp, "gcc")
            self.assertEqual(build_helper._local_cxx_companion(gcc, gcc), gcc)

    def test_non_compiler_stem_returns_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tool = _make_executable(tmp, "rustc")
            _make_executable(tmp, "rustc++")
            self.assertEqual(build_helper._local_cxx_companion(tool, tool), tool)


class AbsolutizeToolPathsTest(unittest.TestCase):
    def test_rust_keys_absolutized(self) -> None:
        env = {"CARGO": "bazel-out/bin/rust/bin/cargo", "RUSTC": "bazel-out/bin/rust/bin/rustc", "RULES_PY_RUST_HOST_SYSROOT": "bazel-out/bin/rust"}
        build_helper._absolutize_tool_paths(env)
        for key in ("CARGO", "RUSTC", "RULES_PY_RUST_HOST_SYSROOT"):
            self.assertTrue(path.isabs(env[key]), key)


class OverrideToolTest(unittest.TestCase):
    def test_absent_key_is_untouched(self) -> None:
        env = {}
        build_helper._override_tool(env, "CC", "/wrap/cc")
        self.assertNotIn("CC", env)

    def test_driver_swapped_flags_preserved(self) -> None:
        env = {"LDSHARED": "gcc -shared -pthread"}
        build_helper._override_tool(env, "LDSHARED", "/wrap/cc")
        self.assertEqual(env["LDSHARED"], "/wrap/cc -shared -pthread")


class MakeCompilerWrapperTest(unittest.TestCase):
    def test_wrapper_is_executable_and_bakes_the_driver(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = build_helper._make_compiler_wrapper(tmp, "cc", "/opt/real-cc")
            self.assertTrue(os.access(wrapper, os.X_OK))
            with open(wrapper) as f:
                content = f.read()
            self.assertIn("/opt/real-cc", content)
            self.assertIn(build_helper._DEBUG_FLAG, content)


class LegacyMetadataConflictTest(unittest.TestCase):
    def _worktree(
        self,
        tmp: str,
        pyproject: str | None = None,
        setup_py: str | None = None,
        setup_cfg: str | None = None,
    ) -> str:
        if pyproject is not None:
            with open(path.join(tmp, "pyproject.toml"), "w") as f:
                f.write(pyproject)
        if setup_py is not None:
            with open(path.join(tmp, "setup.py"), "w") as f:
                f.write(setup_py)
        if setup_cfg is not None:
            with open(path.join(tmp, "setup.cfg"), "w") as f:
                f.write(setup_cfg)
        return tmp

    _SETUPTOOLS_PYPROJECT = (
        '[build-system]\nbuild-backend = "setuptools.build_meta"\n'
        '[project]\nname = "pkg"\nversion = "1.0"\n'
    )

    def test_no_pyproject_is_no_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(tmp, setup_py="install_requires=['x']")
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_setup_py_install_requires_undeclared_in_pyproject_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT,
                setup_py="setup(install_requires=['x'])",
            )
            self.assertTrue(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_static_dependencies_win_over_setup_py(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT + 'dependencies = ["y"]\n',
                setup_py="setup(install_requires=['x'])",
            )
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_dynamic_dependencies_declaration_is_no_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT + 'dynamic = ["dependencies"]\n',
                setup_py="setup(install_requires=['x'])",
            )
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_non_setuptools_backend_is_no_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=(
                    '[build-system]\nbuild-backend = "mesonpy"\n'
                    '[project]\nname = "pkg"\nversion = "1.0"\n'
                ),
                setup_py="setup(install_requires=['x'])",
            )
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_extras_require_in_setup_cfg_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT + 'dependencies = ["y"]\n',
                setup_py="setup()",
                setup_cfg="[options.extras_require]\ndev = pytest",
            )
            self.assertTrue(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))


class WheelPlatformIdentityTest(unittest.TestCase):
    def test_table(self) -> None:
        for target_os, target_cpu, expected in (
            ("linux", "x86_64", ("linux", "x86_64")),
            ("linux", "aarch64", ("linux", "aarch64")),
            ("linux", "x86", ("linux", "i686")),
            ("linux", "arm", ("linux", "armv7l")),
            ("darwin", "aarch64", ("macosx", "arm64")),
            ("darwin", "x86_64", ("macosx", "x86_64")),
            ("windows", "x86_64", ("win", "amd64")),
            ("windows", "aarch64", ("win", "arm64")),
        ):
            with self.subTest(target_os=target_os, target_cpu=target_cpu):
                self.assertEqual(
                    build_helper._wheel_platform_identity(target_os, target_cpu), expected
                )


class WheelPlatformErrorTest(unittest.TestCase):
    def test_no_target_requested_is_exempt(self) -> None:
        self.assertIsNone(
            build_helper._wheel_platform_error(
                "pkg-1.0-cp313-cp313-macosx_11_0_arm64.whl", "", "", host_os="linux"
            )
        )

    def test_none_any_wheels_are_exempt(self) -> None:
        self.assertIsNone(
            build_helper._wheel_platform_error(
                "pkg-1.0-py3-none-any.whl", "linux", "aarch64", host_os="linux"
            )
        )

    def test_matching_tags_pass(self) -> None:
        for filename, target_os, target_cpu, host_os in (
            ("pkg-1.0-cp313-cp313-manylinux_2_17_x86_64.whl", "linux", "x86_64", "linux"),
            ("pkg-1.0-cp313-cp313-musllinux_1_2_x86_64.whl", "linux", "x86_64", "linux"),
            ("pkg-1.0-cp313-cp313-linux_aarch64.whl", "linux", "aarch64", "darwin"),
            ("pkg-1.0-cp313-cp313-linux_armv7l.whl", "linux", "arm", "linux"),
            ("pkg-1.0-cp313-cp313-macosx_11_0_arm64.whl", "darwin", "aarch64", "darwin"),
            ("pkg-1.0-cp313-cp313-macosx_10_9_x86_64.whl", "darwin", "x86_64", "linux"),
            ("PKG-1.0-cp313-cp313-MACOSX_11_0_ARM64.whl", "darwin", "aarch64", "darwin"),
            ("pkg-1.0-cp313-cp313-win_amd64.whl", "windows", "x86_64", "linux"),
            ("pkg-1.0-cp313-cp313-win_arm64.whl", "windows", "aarch64", "linux"),
            ("pkg-1.0-cp313-cp313-macosx_11_0_universal2.whl", "darwin", "aarch64", "darwin"),
            ("pkg-1.0-cp313-cp313-macosx_10_9_universal2.whl", "darwin", "x86_64", "darwin"),
        ):
            with self.subTest(filename=filename):
                self.assertIsNone(
                    build_helper._wheel_platform_error(
                        filename, target_os, target_cpu, host_os=host_os
                    )
                )

    def test_host_os_leak_is_reported_as_leak(self) -> None:
        error = build_helper._wheel_platform_error(
            "pkg-1.0-cp313-cp313-macosx_11_0_arm64.whl", "linux", "aarch64", host_os="darwin"
        )
        self.assertIsNotNone(error)
        self.assertIn("exec host OS 'macosx'", error)

    def test_linux_tag_for_darwin_target_on_linux_host_is_a_leak(self) -> None:
        error = build_helper._wheel_platform_error(
            "pkg-1.0-cp313-cp313-manylinux_2_17_aarch64.whl", "darwin", "aarch64", host_os="linux"
        )
        self.assertIsNotNone(error)
        self.assertIn("exec host OS 'linux'", error)

    def test_wrong_os_without_leak_reports_missing_target_os(self) -> None:
        error = build_helper._wheel_platform_error(
            "pkg-1.0-cp313-cp313-macosx_10_9_x86_64.whl", "windows", "x86_64", host_os="linux"
        )
        self.assertIsNotNone(error)
        self.assertIn("does not contain target OS 'win'", error)

    def test_wrong_cpu_reports_missing_target_cpu(self) -> None:
        error = build_helper._wheel_platform_error(
            "pkg-1.0-cp313-cp313-manylinux_2_17_x86_64.whl", "linux", "aarch64", host_os="linux"
        )
        self.assertIsNotNone(error)
        self.assertIn("does not contain target CPU 'aarch64'", error)

    def test_darwin_tag_spelled_aarch64_fails_cpu_check(self) -> None:
        error = build_helper._wheel_platform_error(
            "pkg-1.0-cp313-cp313-macosx_11_0_aarch64.whl", "darwin", "aarch64", host_os="darwin"
        )
        self.assertIsNotNone(error)
        self.assertIn("target CPU 'arm64'", error)

    def test_universal2_does_not_bypass_non_darwin_targets(self) -> None:
        error = build_helper._wheel_platform_error(
            "pkg-1.0-cp313-cp313-macosx_11_0_universal2.whl", "linux", "aarch64", host_os="linux"
        )
        self.assertIsNotNone(error)
        self.assertIn("does not contain target OS 'linux'", error)

    def test_bare_linux_arm_tag_fails_armv7l_check(self) -> None:
        error = build_helper._wheel_platform_error(
            "pkg-1.0-cp313-cp313-linux_arm.whl", "linux", "arm", host_os="linux"
        )
        self.assertIsNotNone(error)
        self.assertIn("target CPU 'armv7l'", error)


class TargetFlagsTest(unittest.TestCase):
    def test_parser_accepts_and_defaults_target_flags(self) -> None:
        opts, _ = build_helper.PARSER.parse_known_args(["src.tar.gz", "out.whl"])
        self.assertEqual(opts.target_os, "")
        self.assertEqual(opts.target_cpu, "")
        opts, _ = build_helper.PARSER.parse_known_args(
            ["src.tar.gz", "out.whl", "--target-os", "linux", "--target-cpu", "aarch64"]
        )
        self.assertEqual(opts.target_os, "linux")
        self.assertEqual(opts.target_cpu, "aarch64")



def _run_wrapper(wrapper: str, args: list[str]) -> list[str]:
    import subprocess

    result = subprocess.run(
        [wrapper] + args, capture_output=True, text=True, check=True
    )
    return result.stdout.split()


class CrossCompilerWrapperTest(unittest.TestCase):
    """Generates a cross wrapper around an argv-echoing fake compiler and
    asserts the transformed command line."""

    def _wrapper(
        self,
        tmp: str,
        is_darwin: bool = False,
        wrapper_flags: list[str] | None = None,
        static_runtime_archives: list[str] | None = None,
        exe_link_flags: list[str] | None = None,
    ) -> str:
        echo = path.join(tmp, "echo_cc")
        with open(echo, "w") as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$@"\n')
        os.chmod(echo, 0o755)
        return build_helper._make_cross_compiler_wrapper(
            tmp,
            "cc",
            echo,
            wrapper_flags or [],
            is_darwin=is_darwin,
            static_runtime_archives=static_runtime_archives,
            exe_link_flags=exe_link_flags,
        )

    def test_identity_flags_are_reinjected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, wrapper_flags=["-target", "aarch64-linux-gnu"])
            argv = _run_wrapper(wrapper, ["-c", "x.c"])
            self.assertEqual(["-target", "aarch64-linux-gnu", "-c", "x.c"], argv)

    def test_host_linker_leaks_are_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp)
            argv = _run_wrapper(
                wrapper,
                ["-bundle", "-undefined", "dynamic_lookup", "-arch", "arm64", "-shared", "a.o"],
            )
            self.assertEqual(["-shared", "a.o"], argv)

    def test_darwin_target_keeps_bundle_and_adds_dynamic_lookup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, is_darwin=True)
            argv = _run_wrapper(wrapper, ["-bundle", "a.o"])
            self.assertEqual(["-bundle", "a.o", "-Wl,-undefined,dynamic_lookup"], argv)

    def test_darwin_target_respects_existing_dynamic_lookup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, is_darwin=True)
            argv = _run_wrapper(wrapper, ["-bundle", "-undefined", "dynamic_lookup", "a.o"])
            self.assertEqual(["-bundle", "-undefined", "dynamic_lookup", "a.o"], argv)

    def test_probe_invocations_are_left_alone(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, is_darwin=True)
            argv = _run_wrapper(wrapper, ["--version"])
            self.assertEqual(["--version"], argv)

    def test_debug_flag_is_stripped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp)
            argv = _run_wrapper(wrapper, [build_helper._DEBUG_FLAG, "-c", "x.c"])
            self.assertEqual(["-c", "x.c"], argv)

    def test_exe_link_flags_on_every_link(self) -> None:
        # rustc invokes the wrapper as "-C linker" with cargo's own argv —
        # $LDSHARED never reaches it, so the toolchain's crt/search-path
        # flags must be baked in.
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, exe_link_flags=["-B/sys/lib", "--sysroot=/sys"])
            argv = _run_wrapper(wrapper, ["main.o", "-o", "probe"])
            self.assertEqual(["main.o", "-o", "probe", "-B/sys/lib", "--sysroot=/sys"], argv)

    def test_exe_link_flags_not_on_compile_or_probe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, exe_link_flags=["-B/sys/lib"])
            self.assertEqual(["-c", "x.c"], _run_wrapper(wrapper, ["-c", "x.c"]))
            self.assertEqual(["--version"], _run_wrapper(wrapper, ["--version"]))

    def test_lgcc_s_dropped_with_static_runtime(self) -> None:
        # rustc hardcodes -lgcc_s on *-linux-gnu; the llvm toolchain has no
        # libgcc — the unwinder arrives via the static runtime archives.
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, static_runtime_archives=["/tc/libunwind.a"], exe_link_flags=["-B/sys/lib"])
            argv = _run_wrapper(wrapper, ["main.o", "-lgcc_s", "-o", "probe"])
            self.assertNotIn("-lgcc_s", argv)
            self.assertEqual(["main.o", "-o", "probe", "-B/sys/lib", "/tc/libunwind.a"], argv)

    def test_lgcc_s_becomes_lunwind_without_static_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, exe_link_flags=["-B/sys/lib"])
            argv = _run_wrapper(wrapper, ["main.o", "-lgcc_s", "-o", "probe"])
            self.assertEqual(["main.o", "-lunwind", "-o", "probe", "-B/sys/lib"], argv)

    def test_shared_link_lists_static_runtime_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, static_runtime_archives=["/tc/libunwind.a"], exe_link_flags=["-B/sys/lib"])
            argv = _run_wrapper(wrapper, ["a.o", "-shared", "-o", "ext.so"])
            self.assertEqual(1, argv.count("/tc/libunwind.a"))
            self.assertEqual(["a.o", "-shared", "-o", "ext.so", "/tc/libunwind.a", "-B/sys/lib"], argv)


class WrapperFlagExtractionTest(unittest.TestCase):
    def test_identity_flags_extracted_from_cflags(self) -> None:
        self.assertEqual(
            ["-target", "aarch64-linux-gnu", "--sysroot=/abs/sysroot"],
            build_helper._get_wrapper_flags(
                "-O2 -target aarch64-linux-gnu --sysroot=/abs/sysroot -fPIC"
            ),
        )

    def test_relative_sysroot_is_marked(self) -> None:
        flags = build_helper._get_wrapper_flags("--sysroot=external/llvm/sysroot")
        self.assertEqual(1, len(flags))
        self.assertTrue(flags[0].startswith("--sysroot="))
        self.assertIn("external/llvm/sysroot", flags[0])
        self.assertNotEqual("--sysroot=external/llvm/sysroot", flags[0])

    def test_no_identity_flags(self) -> None:
        self.assertEqual([], build_helper._get_wrapper_flags("-O2 -fPIC"))


class GenerateCrossSiteTest(unittest.TestCase):
    def _site(self, target_os: str, target_cpu: str) -> str:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        site_dir = build_helper._generate_cross_site(self.tmp.name, target_os, target_cpu)
        with open(path.join(site_dir, "sitecustomize.py")) as f:
            return f.read()

    def test_linux_identity(self) -> None:
        content = self._site("linux", "aarch64")
        self.assertIn("'aarch64'", content)
        self.assertIn("'Linux'", content)
        self.assertIn("sys.platform = 'linux'", content)

    def test_darwin_machine_is_arm64(self) -> None:
        content = self._site("darwin", "aarch64")
        self.assertIn("'arm64'", content)
        self.assertNotIn("'aarch64'", content)
        self.assertIn("sys.platform = 'darwin'", content)

    def test_manylinux_hook_refuses_compatibility(self) -> None:
        self._site("linux", "x86_64")
        with open(path.join(self.tmp.name, ".cross_site", "_manylinux.py")) as f:
            hook = f.read()
        self.assertIn("return False", hook)


class DarwinKernelReleaseTest(unittest.TestCase):
    def test_known_versions(self) -> None:
        for deployment, expected_major in (("11.0", 20), ("12.5", 21), ("15.0", 24), ("26.0", 25)):
            release = build_helper._darwin_kernel_release(deployment)
            self.assertEqual(expected_major, int(release.split(".")[0]))

    def test_unknown_falls_back(self) -> None:
        self.assertEqual("20.0.0", build_helper._darwin_kernel_release(None))
        self.assertEqual("20.0.0", build_helper._darwin_kernel_release("bogus"))


class MacosDeploymentTargetTest(unittest.TestCase):
    def test_parses_sysconfigdata_literal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = path.join(tmp, "_sysconfigdata__darwin_arm64.py")
            with open(f, "w") as fh:
                fh.write("build_time_vars = {'MACOSX_DEPLOYMENT_TARGET': '11.0'}\n")
            self.assertEqual("11.0", build_helper._macosx_deployment_target(f))

    def test_missing_file_returns_none(self) -> None:
        self.assertIsNone(build_helper._macosx_deployment_target("/nonexistent"))



class MesonCrossFileTest(unittest.TestCase):
    def _cross_file(self, target_os: str, target_cpu: str) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            env = {"CC": "/wrap/cc", "CXX": "/wrap/c++", "AR": "/tools/ar", "STRIP": "/tools/strip"}
            cross_file = build_helper._generate_meson_cross_file(tmp, env, target_os, target_cpu)
            with open(cross_file) as f:
                return f.read()

    def test_binaries_and_host_machine(self) -> None:
        content = self._cross_file("linux", "aarch64")
        self.assertIn("c = '/wrap/cc'", content)
        self.assertIn("cpp = '/wrap/c++'", content)
        self.assertIn("ar = '/tools/ar'", content)
        self.assertIn("system = 'linux'", content)
        self.assertIn("cpu_family = 'aarch64'", content)
        self.assertIn("needs_exe_wrapper = true", content)
        # Anchored to line start: "needs_exe_wrapper" contains the substring.
        self.assertNotIn("\nexe_wrapper =", content)

    def test_longdouble_property_for_known_abis(self) -> None:
        self.assertIn("longdouble_format = 'IEEE_QUAD_LE'", self._cross_file("linux", "aarch64"))
        self.assertIn(
            "longdouble_format = 'INTEL_EXTENDED_16_BYTES_LE'",
            self._cross_file("linux", "x86_64"),
        )
        self.assertIn("longdouble_format = 'IEEE_DOUBLE_LE'", self._cross_file("darwin", "aarch64"))

    def test_no_longdouble_for_unknown_abi(self) -> None:
        self.assertNotIn("longdouble_format", self._cross_file("linux", "arm"))


class CmakeToolchainFileTest(unittest.TestCase):
    def _toolchain(self, target_os: str, target_cpu: str, env: dict[str, str] | None = None) -> tuple[str, str]:
        tmp = tempfile.mkdtemp()
        build_env = env if env is not None else {"CC": "/wrap/cc", "CXX": "/wrap/c++", "AR": "/tools/ar", "STRIP": "/tools/strip"}
        toolchain = build_helper._generate_cmake_toolchain_file(tmp, build_env, target_os, target_cpu)
        with open(toolchain) as f:
            return f.read(), tmp

    def test_compilers_and_system(self) -> None:
        content, _ = self._toolchain("linux", "aarch64")
        self.assertIn('set(CMAKE_SYSTEM_NAME "Linux")', content)
        self.assertIn('set(CMAKE_SYSTEM_PROCESSOR "aarch64")', content)
        self.assertIn('set(CMAKE_C_COMPILER "/wrap/cc")', content)
        self.assertIn('set(CMAKE_CXX_COMPILER "/wrap/c++")', content)
        self.assertIn('set(CMAKE_AR "/tools/ar")', content)
        self.assertIn('set(CMAKE_STRIP "/tools/strip")', content)

    def test_os_titlecased(self) -> None:
        content, _ = self._toolchain("darwin", "aarch64")
        self.assertIn('set(CMAKE_SYSTEM_NAME "Darwin")', content)

    def test_unknown_os_passes_through(self) -> None:
        content, _ = self._toolchain("freebsd", "x86_64")
        self.assertIn('set(CMAKE_SYSTEM_NAME "freebsd")', content)

    def test_ar_strip_default_to_bare_names(self) -> None:
        content, _ = self._toolchain("linux", "x86_64", env={"CC": "/wrap/cc", "CXX": "/wrap/c++"})
        self.assertIn('set(CMAKE_AR "ar")', content)
        self.assertIn('set(CMAKE_STRIP "strip")', content)

    def test_ranlib_routes_ar_s(self) -> None:
        # CMake runs an auto-discovered CMAKE_RANLIB after `ar qc`; left unset
        # that is the host's ranlib against the target's archives. The wrapper
        # must route `ar s` (ranlib's POSIX spelling) through our AR.
        content, tmp = self._toolchain("linux", "x86_64")
        ranlib = path.join(tmp, "cmake_ranlib")
        self.assertIn('set(CMAKE_RANLIB "{}")'.format(ranlib), content)
        with open(ranlib) as f:
            wrapper = f.read()
        self.assertIn('exec "/tools/ar" s "$@"', wrapper)
        self.assertTrue(os.access(ranlib, os.X_OK))

    def test_paths_with_spaces_stay_quoted(self) -> None:
        content, _ = self._toolchain("linux", "x86_64", env={"CC": "/tmp/with space/cc", "CXX": "/tmp/with space/c++"})
        self.assertIn('set(CMAKE_C_COMPILER "/tmp/with space/cc")', content)
        self.assertIn('set(CMAKE_CXX_COMPILER "/tmp/with space/c++")', content)


class ConfigureCargoCrossEnvTest(unittest.TestCase):
    def _env(self) -> dict[str, str]:
        return {"CC": "/wrap/cc", "RUSTC": "/rust/toolchain/bin/rustc"}

    def test_triple_glibc_and_musl(self) -> None:
        env = self._env()
        build_helper._configure_cargo_cross_env(env, tempfile.mkdtemp(), "linux", "aarch64", "glibc")
        self.assertEqual("aarch64-unknown-linux-gnu", env["CARGO_BUILD_TARGET"])
        self.assertEqual("/wrap/cc", env["CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER"])

        env = self._env()
        build_helper._configure_cargo_cross_env(env, tempfile.mkdtemp(), "linux", "aarch64", "musl")
        self.assertEqual("aarch64-unknown-linux-musl", env["CARGO_BUILD_TARGET"])
        self.assertEqual("/wrap/cc", env["CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER"])

    def test_triple_darwin(self) -> None:
        env = self._env()
        build_helper._configure_cargo_cross_env(env, tempfile.mkdtemp(), "darwin", "aarch64", "libsystem")
        self.assertEqual("aarch64-apple-darwin", env["CARGO_BUILD_TARGET"])

    def test_unknown_libc_fails_loudly(self) -> None:
        # A hardcoded -gnu suffix would silently target the wrong ABI; the
        # mapping must refuse what it does not know.
        with self.assertRaises(ValueError):
            build_helper._configure_cargo_cross_env(self._env(), tempfile.mkdtemp(), "linux", "aarch64", "uclibc")

    def test_pyo3_and_maturin_args(self) -> None:
        env = self._env()
        build_helper._configure_cargo_cross_env(env, tempfile.mkdtemp(), "linux", "x86_64", "glibc")
        expected = "{}.{}".format(sys.version_info.major, sys.version_info.minor)
        self.assertEqual(expected, env["PYO3_CROSS_PYTHON_VERSION"])
        self.assertEqual("--interpreter python" + expected, env["MATURIN_PEP517_ARGS"])

    def test_maturin_args_preserve_package_values(self) -> None:
        env = self._env()
        env["MATURIN_PEP517_ARGS"] = "--cargo-extra-args=--features foo"
        build_helper._configure_cargo_cross_env(env, tempfile.mkdtemp(), "linux", "x86_64", "glibc")
        expected = "{}.{}".format(sys.version_info.major, sys.version_info.minor)
        self.assertEqual(
            "--interpreter python{} --cargo-extra-args=--features foo".format(expected),
            env["MATURIN_PEP517_ARGS"],
        )

    def test_rustc_wrapper_uses_merged_sysroot(self) -> None:
        tmp = tempfile.mkdtemp()
        # Fake target toolchain (bin/rustc) and host sysroot with an exec-std entry.
        target_rustc = path.join(tmp, "target_tc", "bin", "rustc")
        makedirs(path.dirname(target_rustc))
        open(target_rustc, "w").close()
        makedirs(path.join(tmp, "target_tc", "lib", "rustlib", "aarch64-unknown-linux-gnu"))
        host_sysroot = path.join(tmp, "host_sysroot")
        makedirs(path.join(host_sysroot, "lib", "rustlib", "aarch64-apple-darwin"))

        env = self._env()
        env["RUSTC"] = target_rustc
        env["RULES_PY_RUST_HOST_SYSROOT"] = host_sysroot
        build_helper._configure_cargo_cross_env(env, tmp, "linux", "aarch64", "glibc")

        wrapper = env["RUSTC"]
        self.assertNotEqual(target_rustc, wrapper)
        with open(wrapper) as f:
            content = f.read()
        self.assertIn("--sysroot", content)
        self.assertTrue(os.access(wrapper, os.X_OK))
        # The merged sysroot exposes the host's rustlib entries (exec std for
        # build scripts) alongside the target's.
        merged = path.join(tmp, ".rust_sysroot", "lib", "rustlib")
        self.assertTrue(path.islink(path.join(merged, "aarch64-apple-darwin")))
        self.assertTrue(path.islink(path.join(merged, "aarch64-unknown-linux-gnu")))


class BuildBackendTest(unittest.TestCase):
    def test_declared_backend(self) -> None:
        data = {"build-system": {"build-backend": "mesonpy"}}
        self.assertEqual("mesonpy", build_helper._build_backend(data))

    def test_missing_cases(self) -> None:
        for data in (None, {}, {"build-system": {}}, {"build-system": "bogus"}, {"build-system": {"build-backend": 3}}):
            self.assertIsNone(build_helper._build_backend(data))


class StaticRuntimeArchivesTest(unittest.TestCase):
    def _wrapper(self, tmp: str, archives: list[str]) -> str:
        echo = path.join(tmp, "echo_cc")
        with open(echo, "w") as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$@"\n')
        os.chmod(echo, 0o755)
        return build_helper._make_cross_compiler_wrapper(
            tmp, "c++", echo, [], static_runtime_archives=archives
        )

    def test_shared_links_append_runtime_archives(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, ["/rt/libc++.a", "/rt/libc++abi.a"])
            argv = _run_wrapper(wrapper, ["-shared", "a.o"])
            self.assertEqual(["-shared", "a.o", "/rt/libc++.a", "/rt/libc++abi.a"], argv)

    def test_compiles_and_probes_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, ["/rt/libc++.a"])
            self.assertEqual(["-c", "x.cc"], _run_wrapper(wrapper, ["-c", "x.cc"]))
            self.assertEqual(["--version"], _run_wrapper(wrapper, ["--version"]))

    def test_no_archives_no_append(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = self._wrapper(tmp, [])
            self.assertEqual(["-shared", "a.o"], _run_wrapper(wrapper, ["-shared", "a.o"]))



if __name__ == "__main__":
    unittest.main()
