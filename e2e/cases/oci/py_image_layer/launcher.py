import sys

import build
import colorama

if __name__ == "__main__":
    print(
        "launcher ok {} {} {}".format(
            sys.version_info.minor,
            build.__version__,
            colorama.__version__,
        )
    )
