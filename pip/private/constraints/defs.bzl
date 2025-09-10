MAJORS = [2, 3]        # There is no 4
MINORS = range(0, 21)
PATCHES = range(0, 31)
INTERPRETERS = [
    "py", # Generic
    "cp", # CPython
    # "jy", # Jython
    # "ip", # IronPython
    # "pp", # PyPy, has its own ABI scheme :|
]
# FIXME: We're ignoring these for now which isn't ideal
FLAGS = {
    "d": "pydebug",
    "m": "pymalloc",
    "t": "freethreading",
    "u": "wide-unicode",  # Deprecated in 3.13
}
