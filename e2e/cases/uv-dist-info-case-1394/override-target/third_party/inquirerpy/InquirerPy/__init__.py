"""Stand-in for the InquirerPy wheel, selected by `uv.override_package(target)`.

Deliberately not the real package: the test asserts this module is what got
installed, which proves the lock's `InquirerPy-0.3.4-py3-none-any.whl` was
never fetched and its `.dist-info` never read.
"""

SUBSTITUTE = True
