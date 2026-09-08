"""
Constants.
"""

MAJORS = [2, 3]  # There is no 4
MINORS = range(0, 21)
INTERPRETERS = [
    "py",  # Generic
    "cp",  # CPython
    # "jy", # Jython
    # "ip", # IronPython
    # "pp", # PyPy, has its own ABI scheme :|
]

# Tag prefixes of interpreters rules_py deliberately does not support. Wheels
# carrying them are skipped silently; unsupported tags outside this set get a
# warning instead, since they usually indicate a malformed wheel filename.
FOREIGN_INTERPRETER_PREFIXES = [
    "pp",  # PyPy python tags (pp310) and abi tags (pypy310_pp73)
    "pypy",
    "graalpy",
    "ip",  # IronPython
    "jy",  # Jython
]

def foreign_interpreter_tag(tag):
    """Predicate.

    Indicate whether a wheel python or abi tag belongs to an interpreter
    rules_py deliberately does not support (PyPy, GraalPy, Jython,
    IronPython).

    Args:
        tag (str): A wheel python or abi tag

    Returns:
        bool; whether the tag names a known foreign interpreter.
    """
    for prefix in FOREIGN_INTERPRETER_PREFIXES:
        if tag.startswith(prefix):
            return True
    return False
