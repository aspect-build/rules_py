import sys

import build
import colorama
import pyproject_hooks
from worker_support import support

if __name__ == "__main__":
    print(
        "worker ok {} {} {} {} {}".format(
            sys.version_info.minor,
            build.__version__,
            colorama.__version__,
            pyproject_hooks.__version__,
            support(),
        )
    )
