"""Importable payload of the reserved-path collision fixture wheel."""

import os
import sys

PREFIX = sys.prefix

BIN_PYTHON = os.path.join(PREFIX, "bin", "python")
PYVENV_CFG = os.path.join(PREFIX, "pyvenv.cfg")
CONSOLE_SCRIPT = os.path.join(PREFIX, "bin", "reserved-cli")
SITE_PACKAGES_INJECTED = os.path.join(
    PREFIX, "lib", "python3.12", "site-packages", "injected.py"
)
LIB_INJECTED = os.path.join(PREFIX, "lib", "libextra.so")
KEPT_FILE = os.path.join(PREFIX, "share", "reserveddata", "kept.txt")


def main() -> int:
    print("reserved-cli console script ran")
    return 0
