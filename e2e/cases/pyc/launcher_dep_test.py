"""A launcher in `deps` forwards its venv's bytecode mapping, so a sourceless
consumer analyzes and imports the launcher's Python closure."""

import pex_lib

assert pex_lib.VALUE == 1
