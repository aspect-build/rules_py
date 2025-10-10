def supported_python(python_tag):
    """Predicate.

    Indicate whether the current `pip` implementation supports the python
    represented by a given wheel abi tag. Allows for filtering out of wheels for
    currently unsupported pythons, being:

    - PyPy which has its own abi versioning scheme
    - Jython
    - IronPython

    Explicitly allows only the `py` (generic) and `cp` (CPython) interpreters.

    Args:
        python_tag (str): A wheel abi tag

    Returns:
        bool; whether the python is supported and can be configured or not.

    """

    # See https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/#python-tag

    if python_tag.startswith("pypy"):
        return False
    elif python_tag.startswith("cp") or python_tag.startswith("py"):
        return True
    else:
        return False
