import subprocess
import sys

import build
import colorama
from bazel_tools.tools.python.runfiles import runfiles

if __name__ == "__main__":
    print(
        "launcher ok {} {} {}".format(
            sys.version_info.minor,
            build.__version__,
            colorama.__version__,
        )
    )
    worker = runfiles.Create().Rlocation(
        "_main/oci/py_image_layer/my_app_worker_bin"
    )
    assert worker is not None
    subprocess.run([worker], check=True)
