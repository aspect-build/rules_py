import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest


_SETUP_PY = textwrap.dedent(
    """\
    import os
    from pathlib import Path
    import shlex
    import subprocess

    from setuptools import Extension, setup

    for key in os.environ.get(
        "NATIVE_TOOLS_TO_PROBE",
        "AR,CC,CXX,LD,STRIP",
    ).split(","):
        command = shlex.split(os.environ[key])
        if not Path(command[0]).is_absolute():
            raise SystemExit(f"{key} executable is not absolute: {command[0]}")
        subprocess.run([*command, "--probe"], check=True)

    ext_modules = (
        [Extension("native_module", ["native.c"])]
        if os.environ.get("BUILD_C_EXTENSION") == "1"
        else []
    )
    setup(
        name="native_tools_test",
        version="1.0",
        py_modules=[],
        ext_modules=ext_modules,
    )
    """
)

_TOOL = """#!/bin/sh
exec {python} - "$@" <<'PY'
import os
from pathlib import Path
import shlex
import shutil
import sys

arguments = sys.argv[1:]
with open(os.environ["NATIVE_TOOL_LOG"], "a") as log:
    print({name} + ":" + shlex.join(arguments), file=log)
if "--probe" in arguments:
    raise SystemExit(0)
if os.environ.get("NATIVE_TOOL_FAKE_OUTPUT") == "1":
    try:
        output = Path(arguments[arguments.index("-o") + 1])
    except (ValueError, IndexError):
        raise SystemExit("synthetic compiler invocation has no -o output")
    output.parent.mkdir(parents=True, exist_ok=True)
    # macOS wheel tagging inspects extension Mach-O headers. Copy the declared
    # test interpreter so compile and link outputs remain synthetic but valid.
    shutil.copyfile(sys.executable, output)
    raise SystemExit(0)
raise SystemExit("unexpected non-probe invocation")
PY
"""


def _write_tool(path, name):
    path.write_text(_TOOL.format(python=shlex.quote(sys.executable), name=repr(name)))
    path.chmod(0o755)
    return path


class BuildHelperNativeToolsTest(unittest.TestCase):
    def test_tools_remain_absolute_after_build_cwd_change(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
            action_root = Path(tmp) / "action-root"
            tools = action_root / "tools"
            relative_bin = action_root / "relative-bin"
            tools.mkdir(parents=True)
            relative_bin.mkdir()

            tool_paths = {}
            for name in ("AR", "CC", "CXX", "STRIP"):
                tool_paths[name] = _write_tool(tools / name.lower(), name)
            tool_paths["LD"] = _write_tool(relative_bin / "ld-driver", "LD")

            package = action_root / "native_tools_test-1.0"
            package.mkdir()
            (package / "setup.py").write_text(_SETUP_PY)
            (package / "native.c").write_text("int native_module(void) { return 0; }\n")
            sdist = action_root / "native_tools_test-1.0.tar.gz"
            with tarfile.open(sdist, "w:gz") as archive:
                archive.add(package, arcname=package.name)

            outdir = action_root / "dist"
            log = action_root / "native-tools.log"
            helper = Path(__file__).with_name("build_helper.py")
            rules_py_root = helper.parents[3]

            env = os.environ.copy()
            for key in (
                "AR",
                "CC",
                "CPP",
                "CXX",
                "LD",
                "LDCXXSHARED",
                "LDSHARED",
                "MPICC",
                "STRIP",
            ):
                env.pop(key, None)
            env.update(
                HOME=tmp,
                LD="ld-driver --ld-default",
                NATIVE_TOOL_LOG=str(log),
                PATH=os.pathsep.join(["relative-bin", env.get("PATH", os.defpath)]),
                PYTHONPATH=os.pathsep.join(
                    [str(rules_py_root), env.get("PYTHONPATH", "")]
                ),
            )

            config = {
                "AR": [str(tool_paths["AR"].relative_to(action_root)), "--ar-default"],
                "CC": [str(tool_paths["CC"].relative_to(action_root)), "--cc-default"],
                "CXX": [
                    str(tool_paths["CXX"].relative_to(action_root)),
                    "--cxx-default",
                ],
                "STRIP": [str(tool_paths["STRIP"]), "--strip-default"],
            }
            result = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "--native-tool-config",
                    json.dumps(config),
                    str(sdist),
                    str(outdir),
                ],
                cwd=action_root,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                0,
                result.returncode,
                "build_helper failed:\nstdout:\n{}\nstderr:\n{}".format(
                    result.stdout,
                    result.stderr,
                ),
            )
            records = {
                key: args
                for key, args in (
                    line.split(":", 1) for line in log.read_text().splitlines()
                )
            }
            self.assertEqual({"AR", "CC", "CXX", "LD", "STRIP"}, set(records))
            for key in records:
                self.assertIn("--{}-default".format(key.lower()), records[key])
                self.assertIn("--probe", records[key])

            c_only_outdir = action_root / "c-only-dist"
            c_only_log = action_root / "c-only-native-tools.log"
            cxx_error = "configured GCC CXX driver is unavailable"
            c_only_config = {
                "CC": [str(tool_paths["CC"].relative_to(action_root))],
                "CXX": {"error": cxx_error},
            }
            c_only_result = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "--native-tool-config",
                    json.dumps(c_only_config),
                    str(sdist),
                    str(c_only_outdir),
                ],
                cwd=action_root,
                env={
                    **env,
                    "BUILD_C_EXTENSION": "1",
                    "NATIVE_TOOL_LOG": str(c_only_log),
                    "NATIVE_TOOL_FAKE_OUTPUT": "1",
                    "NATIVE_TOOLS_TO_PROBE": "CC",
                },
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, c_only_result.returncode, c_only_result.stderr)
            self.assertEqual(1, len(list(c_only_outdir.glob("*.whl"))))
            c_only_records = c_only_log.read_text().splitlines()
            self.assertTrue(c_only_records)
            self.assertTrue(all(record.startswith("CC:") for record in c_only_records))
            self.assertTrue(any("--probe" not in record for record in c_only_records))

            cxx_wrapper = Path(str(c_only_outdir) + ".tmp") / (
                ".aspect_rules_py_compilers/c++"
            )
            cxx_result = subprocess.run(
                [cxx_wrapper, "--probe"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(0, cxx_result.returncode)
            self.assertIn(cxx_error, cxx_result.stderr)


if __name__ == "__main__":
    unittest.main()
