"""debugpy wrapper entrypoint (auto-generated).

Starts a debugpy DAP listener before running the real application.
The IDE can attach to the listener to set breakpoints before any
application code executes.

Environment variables:
    DEBUGPY_HOST: Listen address (default: 127.0.0.1)
    DEBUGPY_PORT: Listen port (default: 5678)
    DEBUGPY_WAIT: Set to "1" to block until a debugger attaches
"""

import os
import runpy
import sys

import debugpy

host = os.environ.get("DEBUGPY_HOST", "127.0.0.1")
port = int(os.environ.get("DEBUGPY_PORT", "5678"))

debugpy.listen((host, port))
print(f"debugpy: listening on {host}:{port}", file=sys.stderr)

if os.environ.get("DEBUGPY_WAIT", "0") == "1":
    print("debugpy: waiting for client to attach...", file=sys.stderr)
    debugpy.wait_for_client()
    print("debugpy: client attached", file=sys.stderr)

# Run the real application entrypoint.
runpy.run_module("%%MAIN_MODULE%%", run_name="__main__", alter_sys=True)
