import os
import shutil
import subprocess
import sys
from pathlib import Path


env = dict(os.environ)
source_root = Path(__file__).parent
generated_root = Path(env["TEST_TMPDIR"]) / "generated"
generated_pkg = generated_root / "pkg"
generated_pkg.mkdir(parents=True)
shutil.copyfile(source_root / "pkg/generated.py", generated_pkg / "generated.py")
logical_root = "_main/py/tests/py-venv-manifest-imports"
manifest = Path(env["TEST_TMPDIR"]) / "MANIFEST"
manifest.write_text(
    f"{logical_root}/pkg/__init__.py {source_root / 'pkg/__init__.py'}\n"
    f"{logical_root}/pkg/generated.py {generated_pkg / 'generated.py'}\n"
)
env["RUNFILES_MANIFEST_FILE"] = str(manifest)
env["RUNFILES_MANIFEST_ONLY"] = "1"
env.pop("RUNFILES_DIR", None)
subprocess.run(
    [
        sys.executable,
        "-c",
        "from pkg.generated import VALUE; assert VALUE == 42",
    ],
    check=True,
    env=env,
)
