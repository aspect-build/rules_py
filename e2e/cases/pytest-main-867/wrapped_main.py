"""Custom test main that wraps the py_pytest_main-generated main().

Reproduces the #1094 use case (setup/teardown around pytest) through the
py_pytest_main macro flow: the generated module must expose an importable
main() rather than running everything under `if __name__ == "__main__"`.
"""

import os
import sys

from __test__wrap_main__ import main

if __name__ == "__main__":
    os.environ["WRAPPED_SETUP_RAN"] = "1"
    sys.exit(main())
