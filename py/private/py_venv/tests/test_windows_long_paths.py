#!/usr/bin/env python3

from windows_long_paths import loadable_path

DIRECTORY = "C:\\" + "d" * 200 + "\\Lib\\site-packages\\"
LONGEST_LOADABLE = DIRECTORY + "m" * (250 - len(DIRECTORY) - len(".pyd")) + ".pyd"
SHORTEST_UNLOADABLE = DIRECTORY + "m" * (251 - len(DIRECTORY) - len(".pyd")) + ".pyd"

assert (
    loadable_path("C:/venv/Lib/site-packages/m.pyd")
    == "C:/venv/Lib/site-packages/m.pyd"
)
assert loadable_path(LONGEST_LOADABLE) == LONGEST_LOADABLE
assert loadable_path(SHORTEST_UNLOADABLE) == "\\\\?\\" + SHORTEST_UNLOADABLE
assert (
    loadable_path(SHORTEST_UNLOADABLE.replace("\\Lib\\", "\\bin\\..\\Lib\\"))
    == "\\\\?\\" + SHORTEST_UNLOADABLE
)
assert (
    loadable_path(SHORTEST_UNLOADABLE.replace("\\", "/"))
    == "\\\\?\\" + SHORTEST_UNLOADABLE
)
assert (
    loadable_path("\\\\server\\share" + SHORTEST_UNLOADABLE[2:])
    == "\\\\?\\UNC\\server\\share" + SHORTEST_UNLOADABLE[2:]
)
assert loadable_path("\\\\?\\" + SHORTEST_UNLOADABLE) == "\\\\?\\" + SHORTEST_UNLOADABLE
