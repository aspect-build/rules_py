#!/usr/bin/env python3
"""No-op binary used to measure py_binary startup overhead.

The total wall-clock time of this process (launcher + Python startup + user
code) is measured externally by hyperfine. Because the program does essentially
nothing, any change in the measured time reflects launcher / venv-setup
regressions rather than application logic.
"""

pass
