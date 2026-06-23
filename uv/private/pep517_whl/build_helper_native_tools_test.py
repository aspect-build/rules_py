import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest


_SETUP_PY = textwrap.dedent(
    """\
    import json
    import os
    from pathlib import Path
    import shutil

    from setuptools import setup

    Path(os.environ["ENV_LOG"]).write_text(json.dumps({
        "CC": os.environ["CC"],
        "COMPOSITE": os.environ["COMPOSITE"],
        "PATH_TOOL": shutil.which("ambient-tool"),
        "TOOLCHAIN_TOOL": os.environ["TOOLCHAIN_TOOL"],
    }))
    setup(name="toolchain_env_test", version="1.0", py_modules=[])
    """
)


def _write_sdist(action_root):
    package = action_root / "toolchain_env_test-1.0"
    package.mkdir()
    (package / "setup.py").write_text(_SETUP_PY)
    sdist = action_root / "toolchain_env_test-1.0.tar.gz"
    with tarfile.open(sdist, "w:gz") as archive:
        archive.add(package, arcname=package.name)
    return sdist


class BuildHelperToolchainEnvTest(unittest.TestCase):
    def test_declared_tool_path_survives_build_cwd(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
            action_root = Path(tmp) / "action-root"
            tools = action_root / "tools"
            tools.mkdir(parents=True)
            toolchain_tool = tools / "toolchain-tool"
            toolchain_tool.write_text("")
            ambient_tool = tools / "ambient-tool"
            ambient_tool.write_text("#!/bin/sh\nexit 0\n")
            ambient_tool.chmod(0o755)

            sdist = _write_sdist(action_root)
            env_log = action_root / "env.json"
            helper = Path(__file__).with_name("build_helper.py")
            env = os.environ.copy()
            env.update(
                CC="c++ -shared",
                COMPOSITE="prefix=tools/toolchain-tool",
                ENV_LOG=str(env_log),
                HOME=tmp,
                PATH=os.pathsep.join(["tools", str(tools), env.get("PATH", "")]),
                PYTHONPATH=os.pathsep.join(
                    [str(helper.parents[3]), env.get("PYTHONPATH", "")]
                ),
                TOOLCHAIN_TOOL=str(toolchain_tool.relative_to(action_root)),
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "--absolutize-toolchain-env",
                    "TOOLCHAIN_TOOL",
                    str(sdist),
                    str(action_root / "dist"),
                ],
                cwd=action_root,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            build_env = json.loads(env_log.read_text())
            self.assertEqual(str(toolchain_tool), build_env["TOOLCHAIN_TOOL"])
            self.assertEqual("prefix=tools/toolchain-tool", build_env["COMPOSITE"])
            self.assertEqual("c++ -shared", build_env["CC"])
            self.assertEqual(str(ambient_tool), build_env["PATH_TOOL"])


if __name__ == "__main__":
    unittest.main()
